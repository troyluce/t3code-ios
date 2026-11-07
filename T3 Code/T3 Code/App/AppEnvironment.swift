import Foundation
import SwiftUI

struct SavedServerProfile: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var serverURL: URL
    var createdAt: Date
    var lastUsedAt: Date
}

@Observable
final class AppEnvironment {
    enum SessionState: Equatable {
        case unconfigured
        case configured(URL)
    }

    var sessionState: SessionState
    var connectionStatus: ConnectionState = .offline
    var threadList: ThreadListStore
    var savedProfiles: [SavedServerProfile] = []
    var activeProfileID: SavedServerProfile.ID?
    var serverConfig: ServerRuntimeConfig?
    var serverConfigError: String?
    private(set) var connection: T3Connection?
    private(set) var client: T3Client?
    private var statusTask: Task<Void, Never>?
    private let profilesDefaultsKey = "savedServerProfiles"
    private let activeProfileDefaultsKey = "activeServerProfileID"
    private let tokenPrefix = "t3.bearer.token.profile."

    init() {
        let bootstrap = Self.bootstrapState()
        self.threadList = ThreadListStore()
        self.savedProfiles = bootstrap.savedProfiles
        self.activeProfileID = bootstrap.activeProfileID
        self.sessionState = bootstrap.sessionState
    }

    func configure(serverURL: URL, bearerToken: String, name: String? = nil) async {
        let profileName = name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? name!.trimmingCharacters(in: .whitespacesAndNewlines)
            : (serverURL.host ?? serverURL.absoluteString)
        let profileID = upsertProfile(serverURL: serverURL, name: profileName)
        KeychainStore.save(bearerToken, account: tokenAccount(for: profileID))
        activeProfileID = profileID
        UserDefaults.standard.set(profileID, forKey: activeProfileDefaultsKey)
        sessionState = .configured(serverURL)
        await startClient(serverURL: serverURL, bearerToken: bearerToken)
    }

    func resumeIfConfigured() async {
        guard let profile = activeProfile ?? savedProfiles.sorted(by: { $0.lastUsedAt > $1.lastUsedAt }).first,
              let token = KeychainStore.read(account: tokenAccount(for: profile.id)) else {
            return
        }
        activeProfileID = profile.id
        UserDefaults.standard.set(profile.id, forKey: activeProfileDefaultsKey)
        markProfileUsed(profile.id)
        sessionState = .configured(profile.serverURL)
        await startClient(serverURL: profile.serverURL, bearerToken: token)
    }

    func switchToProfile(id: SavedServerProfile.ID) async {
        guard let profile = savedProfiles.first(where: { $0.id == id }),
              let token = KeychainStore.read(account: tokenAccount(for: id)) else {
            return
        }
        activeProfileID = id
        UserDefaults.standard.set(id, forKey: activeProfileDefaultsKey)
        markProfileUsed(id)
        sessionState = .configured(profile.serverURL)
        await startClient(serverURL: profile.serverURL, bearerToken: token)
    }

    func renameProfile(id: SavedServerProfile.ID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = savedProfiles.firstIndex(where: { $0.id == id }) else {
            return
        }
        savedProfiles[index].name = trimmed
        persistProfiles()
    }

    func removeProfile(id: SavedServerProfile.ID) async {
        let wasActive = (activeProfileID == id)
        KeychainStore.delete(account: tokenAccount(for: id))
        savedProfiles.removeAll { $0.id == id }
        persistProfiles()

        guard wasActive else { return }

        if let client { await client.stop() }
        client = nil
        connection = nil
        threadList = ThreadListStore()
        serverConfig = nil
        serverConfigError = nil
        connectionStatus = .offline

        if let next = savedProfiles.sorted(by: { $0.lastUsedAt > $1.lastUsedAt }).first {
            activeProfileID = next.id
            UserDefaults.standard.set(next.id, forKey: activeProfileDefaultsKey)
            sessionState = .configured(next.serverURL)
            if let token = KeychainStore.read(account: tokenAccount(for: next.id)) {
                await startClient(serverURL: next.serverURL, bearerToken: token)
            }
        } else {
            activeProfileID = nil
            UserDefaults.standard.removeObject(forKey: activeProfileDefaultsKey)
            sessionState = .unconfigured
        }
    }

    func signOut() async {
        statusTask?.cancel()
        statusTask = nil
        if let client { await client.stop() }
        client = nil
        connection = nil
        if let activeProfileID {
            KeychainStore.delete(account: tokenAccount(for: activeProfileID))
            savedProfiles.removeAll { $0.id == activeProfileID }
            persistProfiles()
            self.activeProfileID = nil
            UserDefaults.standard.removeObject(forKey: activeProfileDefaultsKey)
        }
        if let next = savedProfiles.sorted(by: { $0.lastUsedAt > $1.lastUsedAt }).first {
            self.activeProfileID = next.id
            UserDefaults.standard.set(next.id, forKey: activeProfileDefaultsKey)
            sessionState = .configured(next.serverURL)
        } else {
            sessionState = .unconfigured
        }
        connectionStatus = .offline
        serverConfig = nil
        serverConfigError = nil
        threadList = ThreadListStore()
    }

    private func startClient(serverURL: URL, bearerToken: String) async {
        if let existing = client {
            await existing.stop()
        }
        let protocolVersion: Int
        do {
            let descriptor = try await PairingFlow.fetchEnvironment(serverURL: serverURL)
            protocolVersion = descriptor.orchestrationProtocolVersion ?? 1
            guard (1...2).contains(protocolVersion) else {
                connectionStatus = .error("服务器会话协议版本为 \(protocolVersion)，请更新 iOS 客户端。")
                return
            }
        } catch {
            connectionStatus = .error(ChineseLocalization.errorDescription(error))
            return
        }
        let conn = T3Connection(config: .init(serverURL: serverURL, bearerToken: bearerToken,
                                             orchestrationProtocolVersion: protocolVersion))
        let cli = T3Client(connection: conn, protocolVersion: protocolVersion)
        connection = conn
        client = cli

        let env = self
        await cli.addStatusListener { status in
            Task { @MainActor in
                switch status {
                case .offline:    env.connectionStatus = .offline
                case .connecting: env.connectionStatus = .connecting
                case .connected:  env.connectionStatus = .connected
                case .error(let message): env.connectionStatus = .error(message)
                }
            }
        }

        let connected = await cli.start()
        if connected {
            if let activeProfileID {
                markProfileUsed(activeProfileID)
            }
            await refreshServerConfig()
            await threadList.start(client: cli)
        }
    }

    func refreshServerConfig() async {
        guard let client else { return }
        do {
            let config = try await client.getServerConfig()
            await MainActor.run {
                self.serverConfig = config
                self.serverConfigError = nil
            }
        } catch {
            await MainActor.run {
                self.serverConfigError = ChineseLocalization.errorDescription(error)
            }
        }
    }

    private var activeProfile: SavedServerProfile? {
        guard let activeProfileID else { return nil }
        return savedProfiles.first(where: { $0.id == activeProfileID })
    }

    private func tokenAccount(for profileID: SavedServerProfile.ID) -> String {
        tokenPrefix + profileID
    }

    private func upsertProfile(serverURL: URL, name: String) -> SavedServerProfile.ID {
        let now = Date()
        if let index = savedProfiles.firstIndex(where: { $0.serverURL.absoluteString == serverURL.absoluteString }) {
            savedProfiles[index].name = name
            savedProfiles[index].lastUsedAt = now
            persistProfiles()
            return savedProfiles[index].id
        }
        let profile = SavedServerProfile(
            id: UUID().uuidString,
            name: name,
            serverURL: serverURL,
            createdAt: now,
            lastUsedAt: now
        )
        savedProfiles.append(profile)
        persistProfiles()
        return profile.id
    }

    private func markProfileUsed(_ id: SavedServerProfile.ID) {
        guard let index = savedProfiles.firstIndex(where: { $0.id == id }) else { return }
        savedProfiles[index].lastUsedAt = Date()
        persistProfiles()
    }

    private func loadProfiles() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: profilesDefaultsKey),
           let decoded = try? JSONDecoder().decode([SavedServerProfile].self, from: data) {
            savedProfiles = decoded
        }
        activeProfileID = defaults.string(forKey: activeProfileDefaultsKey)
    }

    private func persistProfiles() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(savedProfiles) {
            UserDefaults.standard.set(data, forKey: profilesDefaultsKey)
        }
    }

    private func migrateLegacySessionIfNeeded() {
        guard savedProfiles.isEmpty,
              let rawURL = KeychainStore.read(.serverURL),
              let url = URL(string: rawURL),
              let token = KeychainStore.read(.bearerToken) else {
            return
        }
        let profile = SavedServerProfile(
            id: UUID().uuidString,
            name: url.host ?? url.absoluteString,
            serverURL: url,
            createdAt: Date(),
            lastUsedAt: Date()
        )
        savedProfiles = [profile]
        activeProfileID = profile.id
        KeychainStore.save(token, account: tokenAccount(for: profile.id))
        KeychainStore.delete(.bearerToken)
        KeychainStore.delete(.serverURL)
        UserDefaults.standard.set(profile.id, forKey: activeProfileDefaultsKey)
        persistProfiles()
    }

    private static func bootstrapState() -> (savedProfiles: [SavedServerProfile], activeProfileID: SavedServerProfile.ID?, sessionState: SessionState) {
        let defaults = UserDefaults.standard
        let profilesKey = "savedServerProfiles"
        let activeKey = "activeServerProfileID"
        let tokenPrefix = "t3.bearer.token.profile."

        var profiles: [SavedServerProfile] = []
        if let data = defaults.data(forKey: profilesKey),
           let decoded = try? JSONDecoder().decode([SavedServerProfile].self, from: data) {
            profiles = decoded
        }
        var activeProfileID = defaults.string(forKey: activeKey)

        if profiles.isEmpty,
           let rawURL = KeychainStore.read(.serverURL),
           let url = URL(string: rawURL),
           let token = KeychainStore.read(.bearerToken) {
            let profile = SavedServerProfile(
                id: UUID().uuidString,
                name: url.host ?? url.absoluteString,
                serverURL: url,
                createdAt: Date(),
                lastUsedAt: Date()
            )
            profiles = [profile]
            activeProfileID = profile.id
            KeychainStore.save(token, account: tokenPrefix + profile.id)
            KeychainStore.delete(.bearerToken)
            KeychainStore.delete(.serverURL)
            defaults.set(profile.id, forKey: activeKey)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let encodedProfiles = try? encoder.encode(profiles) {
                defaults.set(encodedProfiles, forKey: profilesKey)
            }
        }

        let activeProfile = profiles.first(where: { $0.id == activeProfileID })
            ?? profiles.sorted(by: { $0.lastUsedAt > $1.lastUsedAt }).first
        let sessionState: SessionState = activeProfile.map { .configured($0.serverURL) } ?? .unconfigured
        return (profiles, activeProfile?.id, sessionState)
    }
}
