import SwiftUI

// Reusable visual primitives that codify the T3 Code aesthetic:
// flat dark surfaces, hairline borders, pill chips, and small-caps section
// headers. Used across all feature screens to keep the design coherent.

enum T3Style {
    // Card with subtle border and slightly elevated surface.
    struct Card<Content: View>: View {
        var padding: CGFloat = T3Spacing.lg
        var radius: CGFloat = T3Radius.lg
        @ViewBuilder var content: () -> Content

        var body: some View {
            content()
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(T3Color.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(T3Color.separator, lineWidth: 0.5)
                )
        }
    }

    // Small-caps tracked label used above grouped sections.
    struct SectionHeader: View {
        let title: String

        var body: some View {
            Text(title.uppercased())
                .font(T3Typography.caption)
                .foregroundStyle(T3Color.textTertiary)
                .tracking(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // Compact pill used for tags, status, and inline metadata.
    struct Pill: View {
        let text: String
        var systemImage: String? = nil
        var tint: Color = T3Color.textSecondary
        var emphasized: Bool = false

        var body: some View {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(text)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.4)
            }
            .foregroundStyle(emphasized ? tint : T3Color.textTertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(emphasized ? tint.opacity(0.16) : T3Color.surfaceElevated)
            )
            .overlay(
                Capsule()
                    .stroke(emphasized ? tint.opacity(0.30) : T3Color.separator,
                            lineWidth: 0.5)
            )
        }
    }

    // Chip-style toolbar button: icon inside a hairline-bordered rounded square.
    // Matches the desktop toolbar icon-buttons (e.g. square-arrow, plus-minus).
    struct ToolbarChip<Label: View>: View {
        var size: CGFloat = 34
        let action: () -> Void
        @ViewBuilder var label: () -> Label

        var body: some View {
            Button(action: action) {
                label()
                    .frame(width: size, height: size)
                    .background(T3Color.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous)
                            .stroke(T3Color.separator, lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
        }
    }
}

// Renders a label like "T3 Code  ALPHA" used in headers across the app.
struct T3WordmarkLabel: View {
    var size: CGFloat = 17
    var showsAlpha: Bool = true

    var body: some View {
        HStack(spacing: 4) {
            Text("T3")
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(T3Color.textPrimary)
            Text("Code")
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(T3Color.textPrimary)
            if showsAlpha {
                Text("预览版")
                    .font(.system(size: max(9, size - 7), weight: .semibold))
                    .foregroundStyle(T3Color.textTertiary)
                    .tracking(0.4)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(T3Color.surfaceElevated)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(T3Color.separator, lineWidth: 0.5))
                    .padding(.leading, 2)
            }
        }
    }
}
