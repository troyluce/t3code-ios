import SwiftUI

struct ConnectionSetupView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var serverURL: String = ""
    @State private var pairingToken: String = ""
    @State private var isWorking: Bool = false
    @State private var errorMessage: String?
    @FocusState private var focused: Field?

    enum Field { case url, token }

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
                        VStack(alignment: .leading, spacing: T3Spacing.xl) {
                            heroBlock
                            formCard
                            helpCard
                        }
                        .padding(.horizontal, T3Spacing.lg)
                        .padding(.bottom, T3Spacing.xxxl)
                        .frame(maxWidth: 560, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .navigationBarHidden(true)
        }
    }

    private var headerBar: some View {
        HStack {
            T3WordmarkLabel()
            Spacer()
            T3Style.Pill(text: "配对", systemImage: "link",
                         tint: T3Color.warning, emphasized: true)
        }
    }

    private var heroBlock: some View {
        VStack(alignment: .leading, spacing: T3Spacing.sm) {
            Text("将此 iPhone 与 T3 Code 服务器配对。")
                .font(T3Typography.title)
                .foregroundStyle(T3Color.textPrimary)
            Text("打开桌面端的 Settings（设置）→ Connections（连接）→ Network access（网络访问），复制配对链接；也可以分别输入服务器地址和配对令牌。使用 Cloudflare 等隧道时，请使用 HTTPS 地址。")
                .font(T3Typography.callout)
                .foregroundStyle(T3Color.textSecondary)
        }
    }

    private var formCard: some View {
        VStack(alignment: .leading, spacing: T3Spacing.sm) {
            T3Style.SectionHeader(title: "服务器")
            T3Style.Card {
                VStack(alignment: .leading, spacing: T3Spacing.md) {
                    fieldGroup(label: "服务器地址") {
                        TextField("https://t3code-review.belweave.com", text: $serverURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .font(T3Typography.body)
                            .focused($focused, equals: .url)
                    }

                    fieldGroup(label: "配对令牌", trailing: AnyView(
                        Button("粘贴配对链接") { pastePairingLink() }
                            .font(T3Typography.footnote)
                            .foregroundStyle(T3Color.primary)
                    )) {
                        TextField("输入配对令牌", text: $pairingToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(T3Typography.body)
                            .focused($focused, equals: .token)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(T3Typography.footnote)
                            .foregroundStyle(T3Color.danger)
                    }

                    HStack {
                        T3ToolbarButton(title: "连接",
                                        systemImage: "link",
                                        isLoading: isWorking,
                                        isEnabled: canConnect) {
                            Task { await connect() }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, T3Spacing.xs)
                }
            }
        }
    }

    private func fieldGroup<Content: View>(
        label: String,
        trailing: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: T3Spacing.xs) {
            HStack {
                Text(label)
                    .font(T3Typography.footnote)
                    .foregroundStyle(T3Color.textSecondary)
                Spacer()
                if let trailing { trailing }
            }
            content()
                .padding(.horizontal, T3Spacing.md)
                .frame(height: 44)
                .background(T3Color.surfaceMuted)
                .clipShape(RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous)
                        .stroke(T3Color.separator, lineWidth: 0.5)
                )
        }
    }

    private var helpCard: some View {
        VStack(alignment: .leading, spacing: T3Spacing.sm) {
            T3Style.SectionHeader(title: "使用提示")
            T3Style.Card {
                VStack(alignment: .leading, spacing: T3Spacing.sm) {
                    tipRow("支持 Cloudflare Tunnel 等公网 HTTPS 地址，实时连接通过 WSS 建立。")
                    tipRow("也可以通过 Tailscale 或局域网连接，请确保手机能够访问服务器。")
                    tipRow("配对令牌仅使用一次，配对成功后会在本机保存登录会话。")
                }
                .font(T3Typography.footnote)
                .foregroundStyle(T3Color.textSecondary)
            }
        }
    }

    private func tipRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: T3Spacing.sm) {
            Circle().fill(T3Color.primary).frame(width: 4, height: 4).padding(.top, 6)
            Text(text)
        }
    }

    private var canConnect: Bool {
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL), url.scheme != nil, url.host != nil else {
            return false
        }
        return !pairingToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func pastePairingLink() {
        guard let raw = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return }
        if let parsed = PairingFlow.parsePairingURL(raw) {
            serverURL = PairingFlow.serverBaseURL(from: parsed.serverURL).absoluteString
            pairingToken = parsed.token
            errorMessage = nil
        } else if raw.hasPrefix("http"), let url = URL(string: raw) {
            serverURL = PairingFlow.serverBaseURL(from: url).absoluteString
        } else {
            pairingToken = raw
        }
    }

    private func connect() async {
        guard !isWorking else { return }
        guard let rawURL = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = "服务器地址无效"
            return
        }
        let url = PairingFlow.serverBaseURL(from: rawURL)
        let token = pairingToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            errorMessage = "请输入配对令牌"
            return
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            _ = try await PairingFlow.fetchEnvironment(serverURL: url)
            let pair = try await PairingFlow.exchangeToken(serverURL: url, oneTimeToken: token)
            await env.configure(serverURL: url, bearerToken: pair.bearerToken)
        } catch {
            errorMessage = ChineseLocalization.errorDescription(error)
        }
    }
}
