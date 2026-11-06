import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    var isModal: Bool = true
    @State private var confirmSignOut: Bool = false
    @State private var didCopyURL: Bool = false
    @State private var isRefreshingConfig: Bool = false
    @State private var switchingProfileID: SavedServerProfile.ID?
    @State private var renamingProfile: SavedServerProfile?
    @State private var renameDraft: String = ""
    @State private var pendingDeleteProfile: SavedServerProfile?

    @AppStorage("appearance") private var appearanceRaw: String = AppAppearance.system.rawValue
    @AppStorage("accent") private var accentRaw: String = AppAccent.blue.rawValue
    @AppStorage("transcriptDensity") private var transcriptDensityRaw: String = TranscriptDensity.comfortable.rawValue
    @AppStorage("composerSize") private var composerSizeRaw: String = ComposerSize.comfortable.rawValue

    var body: some View {
        NavigationStack {
            ZStack {
                T3Color.surfaceGrouped.ignoresSafeArea()

                VStack(spacing: 0) {
                    headerBar
                        .padding(.horizontal, T3Spacing.lg)
                        .padding(.top, T3Spacing.md)
                        .padding(.bottom, T3Spacing.lg)

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: T3Spacing.xl) {
                            connectionSection
                            appearanceSection
                            chatSection
                            archivedThreadsSection
                            serverSection
                            providersSection
                            aboutSection
                            signOutSection
                        }
                        .padding(.horizontal, T3Spacing.lg)
                        .padding(.bottom, T3Spacing.xxxl)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .navigationBarHidden(true)
            .overlay(alignment: .top) {
                if didCopyURL {
                    Text("地址已复制")
                        .font(T3Typography.caption)
                        .fontWeight(.semibold)
                        .padding(.horizontal, T3Spacing.md)
                        .padding(.vertical, T3Spacing.sm)
                        .background(T3Color.surfaceElevated, in: Capsule())
                        .overlay(Capsule().stroke(T3Color.separator, lineWidth: 0.5))
                        .padding(.top, T3Spacing.sm)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: didCopyURL)
            .confirmationDialog(
                "退出此服务器？",
                isPresented: $confirmSignOut,
                titleVisibility: .visible
            ) {
                Button("退出登录", role: .destructive) {
                    Task {
                        await env.signOut()
                        dismiss()
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("登录令牌将从此设备移除。重新连接时，请通过桌面端再次配对。")
            }
            .confirmationDialog("删除已保存的服务器？",
                                isPresented: Binding(get: { pendingDeleteProfile != nil },
                                                     set: { if !$0 { pendingDeleteProfile = nil } }),
                                titleVisibility: .visible,
                                presenting: pendingDeleteProfile) { profile in
                Button("删除", role: .destructive) {
                    let target = profile
                    pendingDeleteProfile = nil
                    Task { await env.removeProfile(id: target.id) }
                }
                Button("取消", role: .cancel) { pendingDeleteProfile = nil }
            } message: { profile in
                Text("从此设备移除“\(profile.name)”？")
            }
            .sheet(item: $renamingProfile) { profile in
                NavigationStack {
                    Form {
                        TextField("服务器名称", text: $renameDraft)
                            .textInputAutocapitalization(.never)
                    }
                    .navigationTitle("重命名服务器")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { renamingProfile = nil }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                env.renameProfile(id: profile.id, name: renameDraft)
                                renamingProfile = nil
                            }
                            .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .presentationDetents([.height(220)])
            }
        }
    }

    // MARK: - Header bar (matches ThreadsListView)

    private var headerBar: some View {
        HStack(spacing: T3Spacing.sm) {
            T3WordmarkLabel()
            Spacer()
            ConnectionPill(state: env.connectionStatus)
            if isModal {
                T3Style.ToolbarChip(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(T3Color.textPrimary)
                }
            }
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: T3Spacing.sm) {
            T3Style.SectionHeader(title: "连接")
            T3Style.Card {
                VStack(alignment: .leading, spacing: T3Spacing.md) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: T3Spacing.xs) {
                            Text(connectionHeadline)
                                .font(T3Typography.title)
                                .foregroundStyle(T3Color.textPrimary)
                            if case .configured(let url) = env.sessionState {
                                Text(url.host ?? url.absoluteString)
                                    .font(T3Typography.callout)
                                    .foregroundStyle(T3Color.textSecondary)
                                    .lineLimit(1)
                            } else {
                                Text("尚未与服务器配对")
                                    .font(T3Typography.callout)
                                    .foregroundStyle(T3Color.textSecondary)
                            }
                        }
                        Spacer(minLength: T3Spacing.md)
                        ConnectionPill(state: env.connectionStatus)
                    }

                    if let detail = env.connectionStatus.detail {
                        Text(detail)
                            .font(T3Typography.footnote)
                            .foregroundStyle(T3Color.danger)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !env.savedProfiles.isEmpty {
                        Divider().overlay(T3Color.separator)
                        VStack(alignment: .leading, spacing: T3Spacing.sm) {
                            Text("已保存的服务器")
                                .font(T3Typography.callout)
                                .foregroundStyle(T3Color.textSecondary)
                            ForEach(env.savedProfiles.sorted(by: { $0.lastUsedAt > $1.lastUsedAt })) { profile in
                                HStack(spacing: T3Spacing.sm) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(profile.name)
                                            .font(T3Typography.body)
                                            .foregroundStyle(T3Color.textPrimary)
                                            .lineLimit(1)
                                        Text(profile.serverURL.host ?? profile.serverURL.absoluteString)
                                            .font(T3Typography.footnote)
                                            .foregroundStyle(T3Color.textTertiary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: T3Spacing.sm)
                                    if env.activeProfileID == profile.id {
                                        T3Style.Pill(text: "当前使用", tint: T3Color.success, emphasized: true)
                                    } else {
                                        Button {
                                            switchingProfileID = profile.id
                                            Task {
                                                await env.switchToProfile(id: profile.id)
                                                await MainActor.run { switchingProfileID = nil }
                                            }
                                        } label: {
                                            if switchingProfileID == profile.id {
                                                ProgressView()
                                                    .controlSize(.small)
                                            } else {
                                                Text("切换")
                                                    .font(T3Typography.footnote.weight(.semibold))
                                            }
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(switchingProfileID != nil)
                                    }

                                    Menu {
                                        Button {
                                            renameDraft = profile.name
                                            renamingProfile = profile
                                        } label: {
                                            Label("重命名", systemImage: "pencil")
                                        }
                                        Button(role: .destructive) {
                                            pendingDeleteProfile = profile
                                        } label: {
                                            Label("删除", systemImage: "trash")
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(T3Color.textSecondary)
                                            .frame(width: 28, height: 28)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var connectionHeadline: String {
        switch env.connectionStatus {
        case .connected: "已连接"
        case .connecting: "连接中…"
        case .offline: "离线"
        case .error: "连接异常"
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: T3Spacing.sm) {
            T3Style.SectionHeader(title: "外观")
            T3Style.Card {
                VStack(alignment: .leading, spacing: T3Spacing.lg) {
                    VStack(alignment: .leading, spacing: T3Spacing.sm) {
                        Text("显示模式")
                            .font(T3Typography.callout)
                            .foregroundStyle(T3Color.textSecondary)
                        Picker("显示模式", selection: $appearanceRaw) {
                            ForEach(AppAppearance.allCases) { a in
                                Text(a.label).tag(a.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    Divider().overlay(T3Color.separator)

                    VStack(alignment: .leading, spacing: T3Spacing.sm) {
                        Text("主题色")
                            .font(T3Typography.callout)
                            .foregroundStyle(T3Color.textSecondary)
                        HStack(spacing: T3Spacing.md) {
                            ForEach(AppAccent.allCases) { accent in
                                accentSwatch(accent)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private func accentSwatch(_ accent: AppAccent) -> some View {
        let selected = accentRaw == accent.rawValue
        return Button {
            accentRaw = accent.rawValue
        } label: {
            ZStack {
                Circle()
                    .fill(accent.color)
                    .frame(width: 32, height: 32)
                if selected {
                    Circle()
                        .stroke(T3Color.textPrimary.opacity(0.95), lineWidth: 2)
                        .frame(width: 32, height: 32)
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accent.label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: - Chat experience

    private var chatSection: some View {
        VStack(alignment: .leading, spacing: T3Spacing.sm) {
            T3Style.SectionHeader(title: "聊天体验")
            T3Style.Card(padding: T3Spacing.md) {
                VStack(spacing: 0) {
                    settingsMenuRow(
                        title: "消息间距",
                        value: (TranscriptDensity(rawValue: transcriptDensityRaw) ?? .comfortable).label
                    ) {
                        ForEach(TranscriptDensity.allCases) { d in
                            Button(d.label) { transcriptDensityRaw = d.rawValue }
                        }
                    }
                    Divider().overlay(T3Color.separator)
                    settingsMenuRow(
                        title: "输入框高度",
                        value: (ComposerSize(rawValue: composerSizeRaw) ?? .comfortable).label
                    ) {
                        ForEach(ComposerSize.allCases) { s in
                            Button(s.label) { composerSizeRaw = s.rawValue }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Archived threads

    private var archivedThreadsSection: some View {
        VStack(alignment: .leading, spacing: T3Spacing.sm) {
            T3Style.SectionHeader(title: "会话")
            T3Style.Card(padding: T3Spacing.md) {
                NavigationLink {
                    ArchivedThreadsView()
                        .environment(env)
                } label: {
                    HStack(spacing: T3Spacing.md) {
                        Image(systemName: "archivebox")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(T3Color.textSecondary)
                            .frame(width: 28, height: 28)
                            .background(T3Color.surfaceMuted, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text("已归档会话")
                                .font(T3Typography.body)
                                .foregroundStyle(T3Color.textPrimary)
                            Text(archivedSubtitle)
                                .font(T3Typography.footnote)
                                .foregroundStyle(T3Color.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: T3Spacing.sm)
                        if archivedCount > 0 {
                            Text("\(archivedCount)")
                                .font(T3Typography.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(T3Color.textSecondary)
                                .padding(.horizontal, T3Spacing.sm)
                                .padding(.vertical, 4)
                                .background(T3Color.surfaceMuted, in: Capsule())
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(T3Color.textTertiary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var archivedCount: Int {
        env.threadList.threads.filter { $0.archivedAt != nil }.count
    }

    private var archivedSubtitle: String {
        if archivedCount == 0 {
            return "尚未归档任何会话"
        }
        return "已归档 \(archivedCount) 个会话"
    }

    // MARK: - Server

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: T3Spacing.sm) {
            T3Style.SectionHeader(title: "服务器")
            T3Style.Card {
                VStack(alignment: .leading, spacing: T3Spacing.lg) {
                    if case .configured(let url) = env.sessionState {
                        VStack(alignment: .leading, spacing: T3Spacing.sm) {
                            Text("服务地址")
                                .font(T3Typography.callout)
                                .foregroundStyle(T3Color.textSecondary)
                            Text(url.absoluteString)
                                .font(T3Typography.code)
                                .foregroundStyle(T3Color.textPrimary)
                                .padding(.horizontal, T3Spacing.sm)
                                .padding(.vertical, T3Spacing.sm)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(T3Color.surfaceMuted)
                                .clipShape(RoundedRectangle(cornerRadius: T3Radius.sm, style: .continuous))
                                .textSelection(.enabled)
                                .lineLimit(3)
                        }

                        HStack(spacing: T3Spacing.sm) {
                            Button {
                                UIPasteboard.general.string = url.absoluteString
                                didCopyURL = true
                                Task {
                                    try? await Task.sleep(nanoseconds: 1_800_000_000)
                                    didCopyURL = false
                                }
                            } label: {
                                Label("复制", systemImage: "doc.on.doc")
                                    .font(T3Typography.bodyEmphasis)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.bordered)

                            Button {
                                Task {
                                    isRefreshingConfig = true
                                    await env.refreshServerConfig()
                                    isRefreshingConfig = false
                                }
                            } label: {
                                Group {
                                    if isRefreshingConfig {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Label("刷新", systemImage: "arrow.clockwise")
                                    }
                                }
                                .font(T3Typography.bodyEmphasis)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(AppAccent.color(for: accentRaw))
                            .disabled(isRefreshingConfig)
                        }
                    } else {
                        Text("未连接")
                            .font(T3Typography.body)
                            .foregroundStyle(T3Color.textSecondary)
                    }

                    if let err = env.serverConfigError {
                        Divider().overlay(T3Color.separator)
                        Text(err)
                            .font(T3Typography.footnote)
                            .foregroundStyle(T3Color.danger)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    // MARK: - Providers

    @ViewBuilder
    private var providersSection: some View {
        if let config = env.serverConfig, !config.providers.isEmpty {
            VStack(alignment: .leading, spacing: T3Spacing.sm) {
                T3Style.SectionHeader(title: "模型服务商")
                T3Style.Card(padding: T3Spacing.md) {
                    VStack(spacing: 0) {
                        let shown = Array(config.providers.prefix(8))
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, p in
                            providerRow(p)
                            if index < shown.count - 1 {
                                Divider().overlay(T3Color.separator)
                            }
                        }
                    }
                }
                Text("请在桌面服务器中配置。")
                    .font(T3Typography.footnote)
                    .foregroundStyle(T3Color.textTertiary)
                    .padding(.horizontal, T3Spacing.xs)
            }
        }
    }

    private func providerRow(_ p: ServerProvider) -> some View {
        HStack(alignment: .center, spacing: T3Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.label)
                    .font(T3Typography.body)
                    .foregroundStyle(T3Color.textPrimary)
                    .lineLimit(1)
                Text(p.brandDisplayName)
                    .font(T3Typography.footnote)
                    .foregroundStyle(T3Color.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: T3Spacing.sm)
            T3Style.Pill(text: providerStatusLabel(p),
                         tint: providerStatusTint(p),
                         emphasized: true)
        }
        .padding(.vertical, T3Spacing.sm)
    }

    private func providerStatusLabel(_ p: ServerProvider) -> String {
        if p.isUsable { return "就绪" }
        if !p.installed { return "未安装" }
        if !p.enabled { return "已停用" }
        switch p.auth.status {
        case "unauthenticated": return "未认证"
        case "authenticated": return "已认证"
        case "authenticating": return "认证中"
        default: return "需要认证"
        }
    }

    private func providerStatusTint(_ p: ServerProvider) -> Color {
        if p.isUsable { return T3Color.success }
        if !p.enabled || !p.installed { return T3Color.textTertiary }
        return T3Color.warning
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: T3Spacing.sm) {
            T3Style.SectionHeader(title: "关于")
            T3Style.Card(padding: T3Spacing.md) {
                VStack(spacing: 0) {
                    HStack {
                        Text("版本")
                            .font(T3Typography.body)
                            .foregroundStyle(T3Color.textPrimary)
                        Spacer()
                        Text(appVersion)
                            .font(T3Typography.callout)
                            .foregroundStyle(T3Color.textSecondary)
                            .monospacedDigit()
                    }
                    .frame(minHeight: 44)

                    Divider().overlay(T3Color.separator)

                    Link(destination: URL(string: "https://t3.codes")!) {
                        HStack {
                            Text("访问 T3 Code 官网")
                                .font(T3Typography.body)
                                .foregroundStyle(T3Color.textPrimary)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(T3Color.textTertiary)
                        }
                        .frame(minHeight: 44)
                    }
                }
            }
        }
    }

    // MARK: - Sign out

    private var signOutSection: some View {
        VStack(alignment: .leading, spacing: T3Spacing.sm) {
            T3Style.SectionHeader(title: "账户")
            T3Style.Card {
                VStack(alignment: .leading, spacing: T3Spacing.md) {
                    Text("退出后将清除此 iPhone 保存的服务器地址和登录令牌。")
                        .font(T3Typography.footnote)
                        .foregroundStyle(T3Color.textSecondary)
                    Button(role: .destructive) {
                        confirmSignOut = true
                    } label: {
                        Text("退出登录")
                            .font(T3Typography.bodyEmphasis)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(T3Color.danger)
                }
            }
        }
    }

    // MARK: - Primitives

    private func settingsMenuRow<MenuContent: View>(
        title: String,
        value: String,
        @ViewBuilder menu: () -> MenuContent
    ) -> some View {
        HStack {
            Text(title)
                .font(T3Typography.body)
                .foregroundStyle(T3Color.textPrimary)
            Spacer()
            Menu {
                menu()
            } label: {
                HStack(spacing: T3Spacing.xs) {
                    Text(value)
                        .font(T3Typography.callout)
                        .foregroundStyle(T3Color.textPrimary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(T3Color.textTertiary)
                }
                .padding(.horizontal, T3Spacing.md)
                .padding(.vertical, 6)
                .background(T3Color.surfaceMuted, in: Capsule())
                .overlay(Capsule().stroke(T3Color.separator, lineWidth: 0.5))
            }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, T3Spacing.xs)
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(v) (\(b))"
    }
}
