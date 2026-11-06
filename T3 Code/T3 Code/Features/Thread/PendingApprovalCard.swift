import SwiftUI

struct PendingApprovalCard: View {
    let approval: PendingApproval
    let onRespond: (ApprovalDecision) -> Void
    @AppStorage("accent") private var accentRaw: String = AppAccent.blue.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: T3Spacing.md) {
            header
            if let detail = approval.detail, !detail.isEmpty {
                Text(detail)
                    .font(T3Typography.code)
                    .foregroundStyle(T3Color.textPrimary)
                    .padding(.horizontal, T3Spacing.sm)
                    .padding(.vertical, T3Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(T3Color.surfaceMuted)
                    .clipShape(RoundedRectangle(cornerRadius: T3Radius.sm, style: .continuous))
                    .textSelection(.enabled)
            }
            actionRow
        }
        .padding(T3Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T3Color.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: T3Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: T3Radius.lg, style: .continuous)
                .stroke(T3Color.warning.opacity(0.4), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: T3Spacing.sm) {
            Image(systemName: approval.kind.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(T3Color.warning)
                .frame(width: 28, height: 28)
                .background(T3Color.warning.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("需要审批")
                    .font(T3Typography.headline)
                    .foregroundStyle(T3Color.textPrimary)
                Text(approval.kind.displayLabel)
                    .font(T3Typography.footnote)
                    .foregroundStyle(T3Color.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var actionRow: some View {
        VStack(spacing: T3Spacing.sm) {
            HStack(spacing: T3Spacing.sm) {
                approvalButton(.accept,
                               icon: "checkmark",
                               background: T3Color.success,
                               foreground: .white)
                approvalButton(.decline,
                               icon: "xmark",
                               background: T3Color.danger,
                               foreground: .white)
            }
            HStack(spacing: T3Spacing.sm) {
                approvalButton(.acceptForSession,
                               icon: "infinity",
                               background: T3Color.surfaceMuted,
                               foreground: T3Color.textPrimary)
                approvalButton(.cancel,
                               icon: "stop.fill",
                               background: T3Color.surfaceMuted,
                               foreground: T3Color.textSecondary)
            }
        }
    }

    private func approvalButton(_ decision: ApprovalDecision,
                                icon: String,
                                background: Color,
                                foreground: Color) -> some View {
        Button {
            onRespond(decision)
        } label: {
            HStack(spacing: T3Spacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(decision.label)
                    .font(.system(size: 13, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(foreground)
            .background(
                RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous)
                    .stroke(T3Color.separator, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}
