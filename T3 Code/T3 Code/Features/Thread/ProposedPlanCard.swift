import SwiftUI

struct ProposedPlanCard: View {
    let plan: ProposedPlan
    let isImplementing: Bool
    let onImplement: () -> Void
    @AppStorage("accent") private var accentRaw: String = AppAccent.blue.rawValue
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: T3Spacing.md) {
            header
            planBody
            actionRow
        }
        .padding(T3Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T3Color.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: T3Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: T3Radius.lg, style: .continuous)
                .stroke(AppAccent.color(for: accentRaw).opacity(0.45), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: T3Spacing.sm) {
            Image(systemName: "list.bullet.clipboard")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppAccent.color(for: accentRaw))
                .frame(width: 28, height: 28)
                .background(AppAccent.color(for: accentRaw).opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("建议方案")
                    .font(T3Typography.headline)
                    .foregroundStyle(T3Color.textPrimary)
                Text(plan.updatedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: "zh_Hans_CN"))))
                    .font(T3Typography.footnote)
                    .foregroundStyle(T3Color.textTertiary)
            }
            Spacer(minLength: 0)
            Button { isExpanded.toggle() } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(T3Color.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(T3Color.surfaceMuted, in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var planBody: some View {
        let visibleHeight: CGFloat? = isExpanded ? nil : 200
        MarkdownText(source: plan.planMarkdown, baseFont: T3Typography.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxHeight: visibleHeight, alignment: .top)
            .clipped()
            .padding(T3Spacing.md)
            .background(T3Color.surfaceMuted)
            .clipShape(RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous))
    }

    private var actionRow: some View {
        HStack(spacing: T3Spacing.sm) {
            if plan.implementedAt != nil {
                Label("已执行", systemImage: "checkmark.seal.fill")
                    .font(T3Typography.bodyEmphasis)
                    .foregroundStyle(T3Color.success)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                Button(action: onImplement) {
                    HStack(spacing: T3Spacing.xs) {
                        if isImplementing {
                            ProgressView().controlSize(.small).tint(AppAccent.color(for: accentRaw))
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        Text(isImplementing ? "启动中…" : "执行方案")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .padding(.horizontal, T3Spacing.md)
                    .padding(.vertical, 8)
                    .foregroundStyle(AppAccent.color(for: accentRaw))
                    .background(
                        RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous)
                            .fill(T3Color.surfaceElevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous)
                            .stroke(AppAccent.color(for: accentRaw).opacity(0.45), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isImplementing)
            }
        }
    }
}
