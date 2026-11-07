import Foundation

struct EnvironmentDescriptor: Codable, Sendable {
    let policy: String
    let bootstrapMethods: [String]
    let sessionMethods: [String]
    let sessionCookieName: String?
    let serverVersion: String?
    let orchestrationProtocolVersion: Int?

    static func decodeLenient(_ data: Data) -> EnvironmentDescriptor? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let policy = (raw["policy"] as? String) ?? "remote-reachable"
        let bootstrap = (raw["bootstrapMethods"] as? [String]) ?? []
        let session = (raw["sessionMethods"] as? [String]) ?? []
        let cookieName = raw["sessionCookieName"] as? String
        guard raw["serverVersion"] is String || raw["policy"] is String else { return nil }
        return EnvironmentDescriptor(policy: policy,
                                     bootstrapMethods: bootstrap,
                                     sessionMethods: session,
                                     sessionCookieName: cookieName,
                                     serverVersion: raw["serverVersion"] as? String,
                                     orchestrationProtocolVersion: raw["orchestrationProtocolVersion"] as? Int)
    }
}

struct ServerConfig: Codable, Sendable {
    let providerInstances: [ProviderInstance]?

    struct ProviderInstance: Codable, Sendable, Identifiable {
        let id: ProviderInstanceID
        let displayName: String?
        let driver: String?
        let availableModels: [String]?
    }

    private enum CodingKeys: String, CodingKey {
        case providerInstances
    }
}
