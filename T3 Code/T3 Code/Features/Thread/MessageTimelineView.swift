import SwiftUI

struct MessageTimelineView: View {
    @Bindable var store: ThreadStore
    let threadShell: ThreadShell
    @AppStorage("transcriptDensity") private var transcriptDensityRaw: String = TranscriptDensity.comfortable.rawValue
    @AppStorage("accent") private var accentRaw: String = AppAccent.blue.rawValue

    @State private var isNearBottom: Bool = true
    @State private var didInitialScroll: Bool = false
    @State private var hasNewWhileScrolledUp: Bool = false

    private let bottomAnchor = "BOTTOM"
    private let stickyThreshold: CGFloat = 120

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { viewport in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: messageSpacing) {
                            if rows.isEmpty {
                                emptyState.padding(.top, 96)
                            } else {
                                ForEach(rows) { row in
                                    rowView(row)
                                }
                            }
                            Color.clear
                                .frame(height: 1)
                                .id(bottomAnchor)
                        }
                        .padding(.horizontal, horizontalPadding)
                        .padding(.top, T3Spacing.lg)
                        .padding(.bottom, T3Spacing.xxl)
                        .onGeometryChange(for: Bool.self) { geometry in
                            geometry.frame(in: .named("messageTimeline")).maxY
                                - viewport.size.height <= stickyThreshold
                        } action: { near in
                            isNearBottom = near
                            if near { hasNewWhileScrolledUp = false }
                        }
                    }
                    .background(T3Color.surfaceGrouped)
                    .contentShape(Rectangle())
                    .scrollDismissesKeyboard(.interactively)
                    .onTapGesture {
                        UIApplication.dismissKeyboard()
                    }
                    .coordinateSpace(name: "messageTimeline")
                    .onChange(of: rows.count) { _, _ in
                        handleStreamUpdate(proxy: proxy, animated: true)
                    }
                    .onChange(of: store.messages.last?.text) { _, _ in
                        handleStreamUpdate(proxy: proxy, animated: false)
                    }
                    .onChange(of: store.messages.last?.attachments?.count) { _, _ in
                        handleStreamUpdate(proxy: proxy, animated: false)
                    }
                    .onChange(of: latestActivitySignature) { _, _ in
                        handleStreamUpdate(proxy: proxy, animated: false)
                    }
                    .onAppear {
                        guard !didInitialScroll else { return }
                        didInitialScroll = true
                        DispatchQueue.main.async {
                            proxy.scrollTo(bottomAnchor, anchor: .bottom)
                        }
                    }

                    if !isNearBottom && !rows.isEmpty {
                        jumpToLatestButton(proxy: proxy)
                            .padding(.trailing, T3Spacing.lg)
                            .padding(.bottom, T3Spacing.md)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.32, dampingFraction: 0.85), value: isNearBottom)
                .animation(.easeInOut(duration: 0.2), value: hasNewWhileScrolledUp)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: TimelineRow) -> some View {
        switch row {
        case .message(let message):
            MessageBubble(role: message.role,
                          text: message.text,
                          attachments: message.attachments,
                          isStreaming: message.streaming,
                          timestamp: message.createdAt)
                .id(row.id)
        case .activity(let activity):
            ActivityRow(activity: activity)
                .id(row.id)
        }
    }

    // MARK: - Timeline rows

    private enum TimelineRow: Identifiable {
        case message(Message)
        case activity(RenderableActivity)

        var id: String {
            switch self {
            case .message(let m): return "msg:" + m.id.rawValue
            case .activity(let a): return "act:" + a.id
            }
        }

        var createdAt: Date {
            switch self {
            case .message(let m): return m.createdAt
            case .activity(let a): return a.createdAt
            }
        }

        var sortRank: Int {
            // When timestamps tie, render messages after the activities that
            // led to them so the chip flow visually leads into the bubble.
            switch self {
            case .activity: return 0
            case .message: return 1
            }
        }
    }

    private var rows: [TimelineRow] {
        let activityRows: [TimelineRow] = RenderableActivity
            .collapse(store.activities)
            .map { TimelineRow.activity($0) }
        let messageRows: [TimelineRow] = store.messages.map { TimelineRow.message($0) }
        return (activityRows + messageRows).sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.sortRank < rhs.sortRank
        }
    }

    /// A coarse signature that changes when activities arrive or transition
    /// from in-progress to complete, so we can re-trigger sticky scroll.
    private var latestActivitySignature: String {
        guard let last = store.activities.last else { return "" }
        return last.id + ":" + last.kind
    }

    // MARK: - Scroll behavior

    private func handleStreamUpdate(proxy: ScrollViewProxy, animated: Bool) {
        if isNearBottom {
            if animated {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        } else {
            hasNewWhileScrolledUp = true
        }
    }

    private func jumpToLatestButton(proxy: ScrollViewProxy) -> some View {
        let isStreaming = store.messages.last?.streaming == true
        let label = hasNewWhileScrolledUp || isStreaming ? "新消息" : "回到最新消息"
        return Button {
            hasNewWhileScrolledUp = false
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: hasNewWhileScrolledUp || isStreaming
                      ? "arrow.down.circle.fill" : "arrow.down")
                    .font(.system(size: 13, weight: .semibold))
                Text(label)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(accentColor)
            .padding(.horizontal, T3Spacing.md)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous)
                    .fill(T3Color.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous)
                    .stroke(T3Color.separator, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - Layout

    private var density: TranscriptDensity {
        TranscriptDensity(rawValue: transcriptDensityRaw) ?? .comfortable
    }

    private var messageSpacing: CGFloat {
        density == .compact ? T3Spacing.sm : T3Spacing.md
    }

    private var horizontalPadding: CGFloat {
        density == .compact ? T3Spacing.lg : T3Spacing.xl
    }

    private var accentColor: Color {
        AppAccent.color(for: accentRaw)
    }

    private var emptyState: some View {
        VStack(spacing: T3Spacing.md) {
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(accentColor)
                .frame(width: 48, height: 48)
                .background(T3Color.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous)
                        .stroke(T3Color.separator, lineWidth: 0.5)
                )
            VStack(spacing: T3Spacing.xs) {
                Text("就绪")
                    .font(T3Typography.headline)
                    .foregroundStyle(T3Color.textPrimary)
                Text("发送消息，继续此会话。")
                    .font(T3Typography.callout)
                    .foregroundStyle(T3Color.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
