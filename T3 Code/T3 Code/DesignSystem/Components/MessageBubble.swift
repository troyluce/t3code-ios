import SwiftUI
import UIKit

struct MessageBubble: View {
    let role: MessageRole
    let text: String
    let attachments: [ChatImageAttachment]?
    let isStreaming: Bool
    let timestamp: Date
    @AppStorage("transcriptDensity") private var transcriptDensityRaw: String = TranscriptDensity.comfortable.rawValue
    @AppStorage("accent") private var accentRaw: String = AppAccent.blue.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: T3Spacing.sm) {
            if role != .user {
                roleHeader
            }

            if let attachments, !attachments.isEmpty {
                attachmentStrip(attachments)
            }

            if role == .user {
                if !text.isEmpty {
                    userPlainText
                }
            } else if !text.isEmpty {
                MarkdownText(source: text, baseFont: textFont)
            }

            if isStreaming {
                StreamingDots()
                    .padding(.top, T3Spacing.xs)
            }

            HStack(spacing: T3Spacing.xs) {
                Spacer()
                Text(timestamp, style: .time)
                    .font(T3Typography.footnote)
                    .foregroundStyle(T3Color.textTertiary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: T3Radius.lg, style: .continuous)
                .fill(role == .user ? T3Color.surfaceMuted : T3Color.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: T3Radius.lg, style: .continuous)
                .stroke(T3Color.separator, lineWidth: 0.5)
        )
    }

    /// User messages render as plain text — they're authored by the human and
    /// shouldn't accidentally be reformatted by markdown parsing.
    private var userPlainText: some View {
        Text(text)
            .font(textFont)
            .foregroundStyle(T3Color.textPrimary)
            .lineSpacing(3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Role header

    private var roleHeader: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(roleColor)
                .frame(width: 6, height: 6)
            Text(roleLabel)
                .font(T3Typography.caption)
                .foregroundStyle(T3Color.textSecondary)
                .tracking(0.4)
            Spacer()
        }
    }

    private var roleLabel: String {
        switch role {
        case .system: "系统"
        case .assistant: "T3 CODE"
        case .user: "你"
        }
    }

    private var roleColor: Color {
        switch role {
        case .system: T3Color.textTertiary
        case .assistant: AppAccent.color(for: accentRaw)
        case .user: T3Color.textSecondary
        }
    }

    // MARK: - Layout helpers

    private var textFont: Font {
        if density == .compact {
            return text.contains("\n") ? T3Typography.footnote : T3Typography.callout
        }
        return text.contains("\n") ? T3Typography.callout : T3Typography.body
    }

    private var horizontalPadding: CGFloat {
        density == .compact ? T3Spacing.md : T3Spacing.lg
    }

    private var verticalPadding: CGFloat {
        density == .compact ? T3Spacing.md : T3Spacing.lg
    }

    private var density: TranscriptDensity {
        TranscriptDensity(rawValue: transcriptDensityRaw) ?? .comfortable
    }

    private func attachmentStrip(_ items: [ChatImageAttachment]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: T3Spacing.sm) {
                ForEach(items) { att in
                    ChatImageThumbnailView(attachment: att)
                }
            }
        }
    }
}

// MARK: - Chat image thumbnail

private struct ChatImageThumbnailView: View {
    let attachment: ChatImageAttachment

    private let thumbWidth: CGFloat = 160
    private let thumbHeight: CGFloat = 120

    var body: some View {
        Group {
            if let urlStr = attachment.url, let url = URL(string: urlStr) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        placeholder
                    case .empty:
                        ProgressView()
                    @unknown default:
                        placeholder
                    }
                }
                .frame(width: thumbWidth, height: thumbHeight)
                .clipShape(RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous))
            } else if let dataUrl = attachment.dataUrl,
                      let data = Self.dataFromDataURL(dataUrl),
                      let ui = UIImage(data: data) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
                    .frame(width: thumbWidth, height: thumbHeight)
                    .clipShape(RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous))
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: T3Radius.md)
            .fill(T3Color.surfaceMuted)
            .frame(width: thumbWidth, height: thumbHeight)
            .overlay {
                Image(systemName: "photo")
                    .foregroundStyle(T3Color.textTertiary)
            }
    }

    private static func dataFromDataURL(_ string: String) -> Data? {
        if let range = string.range(of: ";base64,", range: string.startIndex..<string.endIndex) {
            let b64 = String(string[range.upperBound...])
            return Data(base64Encoded: b64)
        }
        return Data(base64Encoded: string)
    }
}

// MARK: - Code block

struct CodeBlockView: View {
    let code: String
    let language: String?

    private var isDiffLikeLanguage: Bool {
        guard let language else { return false }
        switch language.lowercased() {
        case "diff", "patch", "udiff", "git":
            return true
        default:
            return false
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isDiffLikeLanguage {
                DiffCodeLines(code: code)
            } else {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(T3Color.textPrimary)
                    .lineSpacing(3)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, T3Spacing.md)
        .padding(.vertical, T3Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T3Color.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous)
                .stroke(T3Color.separator, lineWidth: 0.5)
        )
        .overlay(alignment: .topTrailing) {
            if let language, !language.isEmpty {
                Text(language.lowercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(T3Color.textTertiary)
                    .tracking(0.4)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .padding(.trailing, T3Spacing.sm)
                    .padding(.top, T3Spacing.sm)
            }
        }
    }
}

// MARK: - Diff / patch highlighting

private struct DiffCodeLines: View {
    let code: String

    private var lines: [String] {
        code.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(foreground(for: line))
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func foreground(for line: String) -> Color {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("+++ ") || t.hasPrefix("--- ") {
            return T3Color.textSecondary
        }
        if t.hasPrefix("diff --git") || t.hasPrefix("Index: ") {
            return T3Color.textSecondary
        }
        if t.hasPrefix("@@") {
            return T3Color.warning
        }
        guard let c = line.first else { return T3Color.textPrimary }
        switch c {
        case "+":
            return T3Color.success
        case "-":
            return T3Color.danger
        case " ":
            return T3Color.textPrimary
        default:
            return T3Color.textPrimary
        }
    }
}
