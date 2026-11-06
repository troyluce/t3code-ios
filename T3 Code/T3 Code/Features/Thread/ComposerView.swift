import SwiftUI
import PhotosUI

struct ComposerView: View {
    @Environment(AppEnvironment.self) private var env
    @Bindable var store: ThreadStore
    @State private var draft: String = ""
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var attachments: [LocalAttachment] = []
    @State private var showModelPicker = false
    @FocusState private var focused: Bool
    @AppStorage("composerSize") private var composerSizeRaw: String = ComposerSize.comfortable.rawValue
    @AppStorage("accent") private var accentRaw: String = AppAccent.blue.rawValue

    private let maxChars = 120_000
    private let maxAttachments = 8

    var body: some View {
        VStack(spacing: T3Spacing.sm) {
            if !attachments.isEmpty {
                attachmentRow
            }

            VStack(alignment: .leading, spacing: T3Spacing.sm) {
                textField
                controlRow
            }
            .padding(.horizontal, T3Spacing.md)
            .padding(.top, T3Spacing.md)
            .padding(.bottom, T3Spacing.sm)
            .background(T3Color.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: T3Radius.xl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: T3Radius.xl, style: .continuous)
                    .stroke(focused ? accentColor.opacity(0.55) : T3Color.separator,
                            lineWidth: focused ? 1 : 0.5)
            )
        }
        .padding(.horizontal, T3Spacing.lg)
        .padding(.top, T3Spacing.sm)
        .padding(.bottom, T3Spacing.sm)
        .background(T3Color.surfaceGrouped)
        .onChange(of: pickerItems) { _, items in
            Task { await loadAttachments(items) }
        }
    }

    // MARK: - Text field

    private var textField: some View {
        ZStack(alignment: .topLeading) {
            if draft.isEmpty {
                Text("输入问题，使用 @ 引用文件或文件夹，\n使用 / 查看可用命令")
                    .foregroundStyle(T3Color.textTertiary)
                    .font(T3Typography.callout)
                    .padding(.top, 8)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $draft)
                .focused($focused)
                .frame(height: editorHeight)
                .scrollContentBackground(.hidden)
                .font(T3Typography.callout)
                .foregroundStyle(T3Color.textPrimary)
                .tint(accentColor)
        }
    }

    // MARK: - Bottom control row

    private var controlRow: some View {
        HStack(spacing: T3Spacing.sm) {
            modelChip

            Spacer(minLength: 0)

            // Photos / attachments
            PhotosPicker(selection: $pickerItems,
                         maxSelectionCount: maxAttachments,
                         matching: .images) {
                Image(systemName: "paperclip")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(attachments.count >= maxAttachments
                                     ? T3Color.textTertiary
                                     : T3Color.textSecondary)
                    .frame(width: 34, height: 34)
                    .background(T3Color.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous)
                            .stroke(T3Color.separator, lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .disabled(attachments.count >= maxAttachments)

            sendOrStopButton
        }
    }

    @ViewBuilder
    private var sendOrStopButton: some View {
        if isTurnRunning {
            Button {
                Task { await store.interruptTurn() }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(T3Color.danger)
                    .background(T3Color.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous)
                            .stroke(T3Color.separator, lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("停止当前任务")
        } else {
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(canSend ? accentColor : T3Color.textTertiary)
                    .background(T3Color.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous)
                            .stroke(T3Color.separator, lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("发送消息")
        }
    }

    private var isTurnRunning: Bool {
        store.isTurnRunning
    }

    private var modelChip: some View {
        Button { showModelPicker = true } label: {
            HStack(spacing: 5) {
                if let driver = currentProviderDriver {
                    ProviderIcon(driver: driver, size: 13)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accentColor)
                }
                Text(modelName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(T3Color.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(T3Color.textTertiary)
            }
            .padding(.horizontal, T3Spacing.sm)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous)
                    .fill(T3Color.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous)
                    .stroke(T3Color.separator, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showModelPicker) {
            modelPickerSheet
        }
    }

    private var currentProviderDriver: String? {
        guard let selection = store.detail?.modelSelection else { return nil }
        return env.serverConfig?.providers
            .first { $0.instanceId == selection.instanceId }?
            .driver
    }

    private var modelPickerSheet: some View {
        ModelPickerSheet(
            providers: env.serverConfig?.providers ?? [],
            currentSelection: store.detail?.modelSelection,
            accentColor: accentColor,
            onSelect: { provider, slug in
                selectModel(provider: provider, slug: slug)
            }
        )
    }

    private func selectModel(provider: ServerProvider, slug: String) {
        let selection = ModelSelection(instanceId: provider.instanceId, model: slug)
        Task { await store.updateModelSelection(selection) }
    }

    // MARK: - Attachments

    private var attachmentRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: T3Spacing.sm) {
                ForEach(attachments) { attachment in
                    AttachmentChip(attachment: attachment) {
                        attachments.removeAll { $0.id == attachment.id }
                    }
                }
            }
            .padding(.horizontal, T3Spacing.md)
        }
    }

    // MARK: - Helpers

    private var modelName: String {
        guard let detail = store.detail else { return "模型" }
        return env.serverConfig?.modelDisplayLabel(selection: detail.modelSelection)
            ?? detail.modelSelection.model
    }

    private var editorHeight: CGFloat {
        let lines = max(1, draft.components(separatedBy: .newlines).count)
        let textExtra = min(4, draft.count / 42)
        let visibleLines = min(composerSize.maxLines, max(2, lines + textExtra))
        return CGFloat(visibleLines) * 22 + 12
    }

    private var composerSize: ComposerSize {
        ComposerSize(rawValue: composerSizeRaw) ?? .comfortable
    }

    private var accentColor: Color {
        AppAccent.color(for: accentRaw)
    }

    private var canSend: Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return (!text.isEmpty || !attachments.isEmpty)
            && text.count <= maxChars
            && !store.isSending
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let uploads = attachments.map { $0.upload }
        draft = ""
        attachments = []
        pickerItems = []
        Task {
            await store.sendMessage(text: text,
                                    attachments: uploads,
                                    fallbackModelSelection: nil)
        }
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
}

struct LocalAttachment: Identifiable, Equatable {
    let id = UUID()
    let upload: UploadImage
    let preview: Data

    static func == (lhs: LocalAttachment, rhs: LocalAttachment) -> Bool {
        lhs.id == rhs.id
    }
}

struct AttachmentChip: View {
    let attachment: LocalAttachment
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let image = UIImage(data: attachment.preview) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: T3Radius.sm, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: T3Radius.sm)
                    .fill(T3Color.surfaceMuted)
                    .frame(width: 56, height: 56)
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .offset(x: 6, y: -6)
        }
    }
}
