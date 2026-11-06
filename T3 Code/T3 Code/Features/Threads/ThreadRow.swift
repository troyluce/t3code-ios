import SwiftUI

struct ThreadRow: View {
    let thread: ThreadShell
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        HStack(alignment: .center, spacing: T3Spacing.md) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(stateColor)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: T3Spacing.xs) {
                Text(thread.title)
                    .font(T3Typography.headline)
                    .foregroundStyle(T3Color.textPrimary)
                    .lineLimit(1)
                HStack(spacing: T3Spacing.xs) {
                    Text(modelSubtitleLine)
                        .font(T3Typography.footnote)
                        .foregroundStyle(T3Color.textSecondary)
                        .lineLimit(1)
                    if let branch = thread.branch {
                        Text("·")
                            .font(T3Typography.footnote)
                            .foregroundStyle(T3Color.textTertiary)
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption2)
                            .foregroundStyle(T3Color.textTertiary)
                        Text(branch)
                            .font(T3Typography.footnote)
                            .foregroundStyle(T3Color.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .layoutPriority(1)

            Spacer(minLength: T3Spacing.md)

            HStack(alignment: .center, spacing: T3Spacing.sm) {
                Text(relativeDate)
                    .font(T3Typography.footnote)
                    .foregroundStyle(T3Color.textTertiary)
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)

                if thread.hasPendingApprovals || thread.hasPendingUserInput {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(T3Color.warning)
                        .font(.caption)
                }
                if thread.hasActionableProposedPlan {
                    Image(systemName: "list.bullet.clipboard.fill")
                        .foregroundStyle(T3Color.primary)
                        .font(.caption)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(T3Color.textTertiary)
            }
        }
        .padding(.vertical, T3Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var stateColor: Color {
        switch thread.latestTurn?.state {
        case .running:     T3Color.warning
        case .error:       T3Color.danger
        case .interrupted: T3Color.textTertiary
        case .completed:   T3Color.success
        case .none:        T3Color.textTertiary
        }
    }

    private var iconName: String {
        switch thread.latestTurn?.state {
        case .running: "ellipsis.message"
        case .error: "exclamationmark.triangle"
        case .interrupted: "pause.circle"
        case .completed: "checkmark.circle"
        case .none: "bubble.left"
        }
    }

    private var modelSubtitleLine: String {
        let label = env.serverConfig?.modelDisplayLabel(selection: thread.modelSelection)
            ?? thread.modelSelection.model
        guard let provider = env.serverConfig?.providers.first(where: { $0.instanceId == thread.modelSelection.instanceId }) else {
            return label
        }
        let brand = provider.brandDisplayName
        var parts: [String] = [label, brand]
        if let upstream = provider.upstreamVendorLabel(forModelSlug: thread.modelSelection.model) {
            parts.append(upstream)
        }
        let instance = provider.label
        if instance.caseInsensitiveCompare(brand) != .orderedSame,
           instance.caseInsensitiveCompare(label) != .orderedSame {
            parts.append(instance)
        }
        return parts.joined(separator: " · ")
    }

    private var relativeDate: String {
        let date = thread.latestUserMessageAt ?? thread.updatedAt
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
