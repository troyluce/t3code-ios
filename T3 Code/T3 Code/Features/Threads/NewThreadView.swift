import SwiftUI
import PhotosUI

struct NewThreadView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var prompt: String = ""
    @State private var selectedProjectId: ProjectID?
    @State private var selectedProviderId: ProviderInstanceID?
    @State private var selectedModel: String = ""
    @State private var runtimeMode: RuntimeMode = .fullAccess
    @State private var interactionMode: ProviderInteractionMode = .default
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var attachments: [LocalAttachment] = []
    @State private var showModelPicker = false
    @FocusState private var promptFocused: Bool

    @AppStorage("accent") private var accentRaw: String = AppAccent.blue.rawValue

    private let maxChars = 120_000
    private let maxAttachments = 8

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
                            projectSection
                            messageSection
                            modelSection
                            modeSection
                            if let errorMessage {
                                Text(errorMessage)
                                    .font(T3Typography.footnote)
                                    .foregroundStyle(T3Color.danger)
                                    .textSelection(.enabled)
                                    .padding(.horizontal, T3Spacing.xs)
                            }
                        }
                        .padding(.horizontal, T3Spacing.lg)
                        .padding(.bottom, T3Spacing.xxxl)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .navigationBarHidden(true)
            .task {
                await env.refreshServerConfig()
                applyInitialSelections()
            }
            .onChange(of: env.threadList.projects) { _, _ in applyInitialSelections() }
            .onChange(of: env.serverConfig?.providers) { _, _ in applyInitialSelections() }
            .onChange(of: selectedProviderId) { _, _ in
                selectedModel = resolvedModelForSelectedProvider()
            }
            .onChange(of: pickerItems) { _, items in
                Task { await loadAttachments(items) }
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: T3Spacing.sm) {
            T3Style.ToolbarChip(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(T3Color.textPrimary)
            }
            VStack(alignment: .leading, spacing: 2) {
                T3WordmarkLabel()
                Text("开始新的对话")
                    .font(T3Typography.footnote)
                    .foregroundStyle(T3Color.textTertiary)
            }
            Spacer()
            createButton
        }
    }

    private var createButton: some View {
        Button {
            Task { await createThread() }
        } label: {
            Group {
                if isCreating {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Text("创建")
                        .font(.system(size: 14, weight: .semibold))
                }
            }
            .frame(minWidth: 64, minHeight: 36)
            .padding(.horizontal, T3Spacing.md)
            .background(canCreate ? AppAccent.color(for: accentRaw) : T3Color.surfaceMuted)
            .foregroundStyle(canCreate ? .white : T3Color.textTertiary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!canCreate)
    }

    // MARK: - Project

    @ViewBuilder
    private var projectSection: some View {
        VStack(alignment: .leading, spacing: T3Spacing.sm) {
            T3Style.SectionHeader(title: "项目")
            T3Style.Card(padding: T3Spacing.md) {
                if env.threadList.projects.isEmpty {
                    Text("桌面服务器没有可用项目。")
                        .font(T3Typography.callout)
                        .foregroundStyle(T3Color.textSecondary)
                        .padding(.vertical, T3Spacing.sm)
                } else {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedProject?.title ?? "选择项目")
                                .font(T3Typography.body)
                                .foregroundStyle(T3Color.textPrimary)
                            if let project = selectedProject {
                                Text(project.workspaceRoot)
                                    .font(T3Typography.footnote)
                                    .foregroundStyle(T3Color.textTertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Menu {
                            ForEach(env.threadList.projects) { project in
                                Button {
                                    selectedProjectId = project.id
                                } label: {
                                    if selectedProjectId == project.id {
                                        Label(project.title, systemImage: "checkmark")
                                    } else {
                                        Text(project.title)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(T3Color.textTertiary)
                                .frame(width: 32, height: 32)
                                .background(T3Color.surfaceMuted, in: Circle())
                        }
                    }
                    .padding(.vertical, T3Spacing.xs)
                }
            }
        }
    }

    // MARK: - Message

    private var messageSection: some View {
        VStack(alignment: .leading, spacing: T3Spacing.sm) {
            T3Style.SectionHeader(title: "消息")
            T3Style.Card(padding: T3Spacing.md) {
                VStack(alignment: .leading, spacing: T3Spacing.sm) {
                    if !attachments.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: T3Spacing.sm) {
                                ForEach(attachments) { attachment in
                                    AttachmentChip(attachment: attachment) {
                                        attachments.removeAll { $0.id == attachment.id }
                                    }
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: T3Spacing.xs) {
                        ZStack(alignment: .topLeading) {
                            if prompt.isEmpty {
                                Text("向 T3 Code 提问…")
                                    .foregroundStyle(T3Color.textTertiary)
                                    .font(T3Typography.body)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                            TextEditor(text: $prompt)
                                .focused($promptFocused)
                                .frame(minHeight: 120, maxHeight: 220)
                                .scrollContentBackground(.hidden)
                                .font(T3Typography.body)
                        }
                        HStack {
                            PhotosPicker(selection: $pickerItems,
                                         maxSelectionCount: maxAttachments,
                                         matching: .images) {
                                Label("照片", systemImage: "paperclip")
                                    .font(T3Typography.footnote)
                                    .foregroundStyle(attachments.count >= maxAttachments
                                                     ? T3Color.textTertiary
                                                     : T3Color.textSecondary)
                            }
                            .disabled(attachments.count >= maxAttachments)

                            Spacer()
                            Text("\(prompt.count) / \(maxChars)")
                                .font(T3Typography.caption)
                                .foregroundStyle(prompt.count > maxChars ? T3Color.danger : T3Color.textTertiary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Model

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: T3Spacing.sm) {
            T3Style.SectionHeader(title: "模型")
            T3Style.Card(padding: T3Spacing.md) {
                if usableProviders.isEmpty {
                    Text(providerEmptyMessage)
                        .font(T3Typography.callout)
                        .foregroundStyle(T3Color.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, T3Spacing.sm)
                } else {
                    Button {
                        showModelPicker = true
                    } label: {
                        HStack {
                            Text("模型")
                                .font(T3Typography.body)
                                .foregroundStyle(T3Color.textPrimary)
                            Spacer()
                            HStack(spacing: T3Spacing.xs) {
                                if let driver = selectedProvider?.driver {
                                    ProviderIcon(driver: driver, size: 12)
                                }
                                Text(newThreadModelSummary)
                                    .font(T3Typography.callout)
                                    .foregroundStyle(T3Color.textPrimary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.trailing)
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
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .padding(.horizontal, T3Spacing.xs)
                    .sheet(isPresented: $showModelPicker) {
                        ModelPickerSheet(
                            providers: env.serverConfig?.providers ?? [],
                            currentSelection: ModelSelection(
                                instanceId: selectedProviderId ?? ProviderInstanceID(rawValue: ""),
                                model: selectedModel
                            ),
                            accentColor: AppAccent.color(for: accentRaw),
                            onSelect: { provider, slug in
                                selectedProviderId = provider.instanceId
                                selectedModel = slug
                            }
                        )
                    }
                }
            }
        }
    }

    private var newThreadModelSummary: String {
        guard let provider = selectedProvider, !selectedModel.isEmpty else {
            return "选择模型"
        }
        let name = provider.modelLabel(selectedModel)
        let brand = provider.brandDisplayName
        if let upstream = provider.upstreamVendorLabel(forModelSlug: selectedModel) {
            return "\(name) · \(brand) · \(upstream)"
        }
        return "\(name) · \(brand) · \(provider.label)"
    }

    private func isCatalogEntrySelected(_ entry: ModelCatalogEntry) -> Bool {
        selectedProviderId == entry.provider.instanceId && selectedModel == entry.model.slug
    }

    // MARK: - Mode

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: T3Spacing.sm) {
            T3Style.SectionHeader(title: "模式")
            T3Style.Card {
                VStack(alignment: .leading, spacing: T3Spacing.lg) {
                    VStack(alignment: .leading, spacing: T3Spacing.sm) {
                        Text("会话模式")
                            .font(T3Typography.callout)
                            .foregroundStyle(T3Color.textSecondary)
                        Picker("会话模式", selection: $interactionMode) {
                            Text("执行").tag(ProviderInteractionMode.default)
                            Text("规划").tag(ProviderInteractionMode.plan)
                        }
                        .pickerStyle(.segmented)
                        .disabled(selectedProvider?.showInteractionModeToggle == false)
                    }

                    Divider().overlay(T3Color.separator)

                    VStack(alignment: .leading, spacing: T3Spacing.sm) {
                        Text("权限")
                            .font(T3Typography.callout)
                            .foregroundStyle(T3Color.textSecondary)
                        Picker("权限", selection: $runtimeMode) {
                            Text("逐项审批").tag(RuntimeMode.approvalRequired)
                            Text("自动编辑").tag(RuntimeMode.autoAcceptEdits)
                            Text("自动").tag(RuntimeMode.automatic)
                            Text("完全访问").tag(RuntimeMode.fullAccess)
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private var usableProviders: [ServerProvider] {
        (env.serverConfig?.providers ?? [])
            .filter(\.isUsable)
            .sorted { $0.label < $1.label }
    }

    private var selectedProject: ProjectShell? {
        guard let selectedProjectId else { return env.threadList.projects.first }
        return env.threadList.project(id: selectedProjectId)
    }

    private var selectedProvider: ServerProvider? {
        guard let selectedProviderId else { return usableProviders.first }
        return usableProviders.first { $0.instanceId == selectedProviderId }
    }

    private var providerEmptyMessage: String {
        if let error = env.serverConfigError {
            return error
        }
        return env.serverConfig == nil
            ? "正在加载服务商…"
            : "没有已安装并完成认证的可用服务商。"
    }

    private var canCreate: Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return !isCreating
            && selectedProject != nil
            && selectedProvider != nil
            && !selectedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!trimmed.isEmpty || !attachments.isEmpty)
            && prompt.count <= maxChars
    }

    private func applyInitialSelections() {
        if selectedProjectId == nil {
            selectedProjectId = env.threadList.projects.first?.id
        }
        if selectedProviderId == nil {
            selectedProviderId = usableProviders.first?.instanceId
        }
        if selectedModel.isEmpty {
            selectedModel = resolvedModelForSelectedProvider()
        }
    }

    private func resolvedModelForSelectedProvider() -> String {
        selectedProvider?.defaultModel ?? ""
    }

    private func loadAttachments(_ items: [PhotosPickerItem]) async {
        var loaded: [LocalAttachment] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let mime = item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
            let name = "image-\(UUID().uuidString.prefix(6)).\(mime.split(separator: "/").last ?? "jpg")"
            let dataUrl = "data:\(mime);base64,\(data.base64EncodedString())"
            let upload = UploadImage(name: String(name),
                                     mimeType: mime,
                                     sizeBytes: data.count,
                                     dataURL: dataUrl)
            loaded.append(LocalAttachment(upload: upload, preview: data))
            if loaded.count >= maxAttachments { break }
        }
        await MainActor.run {
            attachments = loaded
        }
    }

    private func createThread() async {
        guard let client = env.client,
              let project = selectedProject,
              let provider = selectedProvider else { return }

        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let uploads = attachments.map { $0.upload }
        let selection = project.defaultModelSelection?.instanceId == provider.instanceId
            && project.defaultModelSelection?.model == selectedModel
            ? project.defaultModelSelection!
            : ModelSelection(instanceId: provider.instanceId, model: selectedModel)

        await MainActor.run {
            isCreating = true
            errorMessage = nil
        }
        defer { Task { @MainActor in isCreating = false } }

        do {
            _ = try await client.createThreadAndStart(
                project: project,
                text: text,
                attachments: uploads,
                modelSelection: selection,
                runtimeMode: runtimeMode,
                interactionMode: interactionMode
            )
            await MainActor.run {
                attachments = []
                pickerItems = []
                dismiss()
            }
        } catch {
            await MainActor.run { errorMessage = ChineseLocalization.errorDescription(error) }
        }
    }
}
