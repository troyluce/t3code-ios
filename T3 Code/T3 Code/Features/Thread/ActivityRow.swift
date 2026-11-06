import SwiftUI

/// Compact inline timeline row that renders a single agent activity (tool run,
/// task progress, file edit) between assistant/user messages.
///
/// Designed for mobile chat: small footprint, leading tone bar, optional
/// tap-to-expand for details that would otherwise dominate the timeline.
struct ActivityRow: View {
    let activity: RenderableActivity
    @State private var isExpanded: Bool = false
    @AppStorage("accent") private var accentRaw: String = AppAccent.blue.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggleExpanded) {
                summaryRow
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .disabled(!hasExpansion)

            if isExpanded {
                expandedDetail
                    .padding(.top, T3Spacing.sm)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, T3Spacing.md)
        .padding(.vertical, T3Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T3Color.surfaceElevated.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(toneColor)
                .frame(width: 2.5)
                .padding(.vertical, 6)
        }
        .overlay(
            RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous)
                .stroke(T3Color.separator, lineWidth: 0.5)
        )
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(hasExpansion ? "轻点两下\(isExpanded ? "收起" : "展开")详情" : "")
    }

    private var summaryRow: some View {
        HStack(alignment: .top, spacing: T3Spacing.sm) {
            iconView
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title)
                    .font(T3Typography.footnote.weight(.semibold))
                    .foregroundStyle(T3Color.textPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let preview = inlinePreview {
                    Text(preview)
                        .font(.system(.caption, design: previewIsCommand ? .monospaced : .default))
                        .foregroundStyle(T3Color.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if hasExpansion {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(T3Color.textTertiary)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var iconView: some View {
        ZStack {
            Circle()
                .fill(toneColor.opacity(0.16))
                .frame(width: 22, height: 22)
            if activity.isInProgress {
                ProgressView()
                    .controlSize(.mini)
                    .tint(toneColor)
            } else {
                Image(systemName: activity.iconName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(toneColor)
            }
        }
        .padding(.top, 1)
    }

    @ViewBuilder
    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: T3Spacing.sm) {
            if let command = activity.command, !command.isEmpty {
                Text(command)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(T3Color.textPrimary)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, T3Spacing.sm)
                    .padding(.vertical, 6)
                    .background(T3Color.surfaceMuted,
                                in: RoundedRectangle(cornerRadius: T3Radius.sm, style: .continuous))
                    .textSelection(.enabled)
            }
            if !activity.changedFiles.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(activity.changedFiles.enumerated()), id: \.offset) { _, file in
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 9))
                                .foregroundStyle(T3Color.textTertiary)
                            Text(file)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(T3Color.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            if let detail = expandableDetail {
                Text(detail)
                    .font(T3Typography.footnote)
                    .foregroundStyle(T3Color.textSecondary)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Derivations

    private var inlinePreview: String? {
        if let command = activity.command, !command.isEmpty {
            return firstLine(command)
        }
        if !activity.changedFiles.isEmpty {
            if activity.changedFiles.count == 1 {
                return activity.changedFiles[0]
            }
            return "\(activity.changedFiles.count) 个文件"
        }
        if let detail = activity.detail, !detail.isEmpty {
            return firstLine(detail)
        }
        return nil
    }

    private var previewIsCommand: Bool {
        activity.command?.isEmpty == false
    }

    /// Detail to show in expanded view — only when it has more than what's
    /// already in the inline preview (multi-line or long).
    private var expandableDetail: String? {
        guard let detail = activity.detail else { return nil }
        if detail.contains("\n") || detail.count > 80 { return detail }
        return nil
    }

    private var hasExpansion: Bool {
        if let command = activity.command, !command.isEmpty { return true }
        if !activity.changedFiles.isEmpty { return true }
        return expandableDetail != nil
    }

    private func firstLine(_ s: String) -> String {
        if let nl = s.firstIndex(of: "\n") {
            return String(s[..<nl])
        }
        return s
    }

    private var toneColor: Color {
        switch activity.tone {
        case .info: T3Color.textSecondary
        case .tool: AppAccent.color(for: accentRaw)
        case .thinking: T3Color.warning
        case .error: T3Color.danger
        case .approval: T3Color.warning
        case .success: T3Color.success
        }
    }

    private func toggleExpanded() {
        guard hasExpansion else { return }
        isExpanded.toggle()
    }

    private var accessibilityLabel: String {
        var parts: [String] = [activity.title]
        if let preview = inlinePreview { parts.append(preview) }
        return parts.joined(separator: ", ")
    }
}
