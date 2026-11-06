import SwiftUI

struct ThreadView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var store: ThreadStore
    @State private var isImplementingPlan: Bool = false
    @State private var showRenameSheet: Bool = false
    @State private var showDiffSheet: Bool = false
    @State private var gitStatus: VcsStatusSummary?
    @State private var gitStatusError: String?
    @State private var isRefreshingGitStatus: Bool = false
    @State private var isRunningGitAction: Bool = false
    @State private var commitMessageDraft: String = ""
    @State private var renameDraft: String = ""
    @State private var showGitSheet: Bool = false
    @State private var commitInlineExpanded: Bool = false
    @State private var confirmPullPresented: Bool = false
    @State private var confirmPushPresented: Bool = false
    @State private var gitToast: GitToastInfo?
    @State private var gitToastDismissTask: Task<Void, Never>?
    @AppStorage("accent") private var accentRaw: String = AppAccent.blue.rawValue
    let threadShell: ThreadShell

    init(threadShell: ThreadShell) {
        self.threadShell = threadShell
        _store = State(initialValue: ThreadStore(threadId: threadShell.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            ThreadHeaderView(thread: resolvedThread,
                             project: env.threadList.project(id: threadShell.projectId),
                             session: store.session,
                             onBack: { dismiss() },
                             onRename: { showRenameSheet = true },
                             onSetInteractionMode: { mode in
                                 Task { await store.setInteractionMode(mode) }
                             },
                             onSetRuntimeMode: { mode in
                                 Task { await store.setRuntimeMode(mode) }
                             },
                             onViewDiffs: { showDiffSheet = true },
                             onArchive: archiveThread,
                             onUnarchive: unarchiveThread,
                             onDelete: deleteThread,
                             isArchived: threadShell.archivedAt != nil,
                             onOpenGit: gitCwd == nil ? nil : { openGitSheet() },
                             gitIndicatorTint: gitIndicatorTint)
            MessageTimelineView(store: store, threadShell: threadShell)
            actionablePanels
            ComposerView(store: store)
        }
        .background(T3Color.surfaceGrouped)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            guard let client = env.client else { return }
            await store.start(client: client)
            await refreshGitStatus()
        }
        .onDisappear {
            Task { await store.stop() }
        }
        .sheet(isPresented: $showRenameSheet) {
            ThreadRenameSheet(initial: store.detail?.title ?? threadShell.title) { newTitle in
                showRenameSheet = false
                Task { await renameThread(newTitle) }
            } onCancel: {
                showRenameSheet = false
            }
            .presentationDetents([.height(220), .medium])
        }
        .sheet(isPresented: $showDiffSheet) {
            ThreadDiffSheet(changes: store.diffChanges)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showGitSheet) {
            gitSheet
        }
    }

    @ViewBuilder
    private var actionablePanels: some View {
        VStack(spacing: T3Spacing.md) {
            if let plan = store.latestProposedPlan {
                ProposedPlanCard(plan: plan,
                                 isImplementing: isImplementingPlan) {
                    Task { await implementPlan(plan) }
                }
            }

            ForEach(store.pendingApprovals) { approval in
                PendingApprovalCard(approval: approval) { decision in
                    Task { await store.respondApproval(approval, decision: decision) }
                }
            }

            ForEach(store.pendingUserInputs) { input in
                PendingUserInputCard(pendingInput: input) { answers in
                    Task { await store.respondUserInput(input, answers: answers) }
                }
            }

            if let lastError = store.lastError {
                Text(lastError)
                    .font(T3Typography.footnote)
                    .foregroundStyle(T3Color.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(T3Spacing.md)
                    .background(T3Color.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous))
            }
        }
        .padding(.horizontal, T3Spacing.lg)
        .padding(.bottom, store.pendingApprovals.isEmpty
                          && store.pendingUserInputs.isEmpty
                          && store.latestProposedPlan == nil
                          && store.lastError == nil ? 0 : T3Spacing.sm)
    }

    private func openGitSheet() {
        commitInlineExpanded = false
        commitMessageDraft = ""
        showGitSheet = true
        Task { await refreshGitStatus() }
    }

    private var gitIndicatorTint: Color? {
        guard let status = gitStatus, status.isRepo else { return nil }
        if status.behindCount > 0 { return T3Color.warning }
        if status.hasWorkingTreeChanges || status.aheadCount > 0 || status.hasUpstream == false {
            return AppAccent.color(for: accentRaw)
        }
        return nil
    }

    private var gitSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: T3Spacing.lg) {
                    if let status = gitStatus, let cwd = gitCwd {
                        if !status.isRepo {
                            Text("当前目录不是 Git 仓库。")
                                .font(T3Typography.footnote)
                                .foregroundStyle(T3Color.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            gitStatusBlock(status: status, cwd: cwd)
                            if status.hasWorkingTreeChanges {
                                gitFilesList(status: status)
                            }
                            if commitInlineExpanded {
                                commitInlineEditor(status: status)
                            } else {
                                gitActionRow(status: status)
                            }
                            if let gitToast {
                                gitToastView(gitToast)
                            }
                        }
                    } else if let gitStatusError {
                        Text(gitStatusError)
                            .font(T3Typography.footnote)
                            .foregroundStyle(T3Color.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        HStack(spacing: T3Spacing.sm) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在加载 Git 状态…")
                                .font(T3Typography.footnote)
                                .foregroundStyle(T3Color.textSecondary)
                        }
                    }
                }
                .padding(T3Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(T3Color.surfaceGrouped)
            .navigationTitle("Git")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await refreshGitStatus() }
                    } label: {
                        if isRefreshingGitStatus {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isRefreshingGitStatus)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showGitSheet = false }
                }
            }
            .confirmationDialog(pullConfirmTitle,
                                isPresented: $confirmPullPresented,
                                titleVisibility: .visible) {
                Button("拉取", role: .none) {
                    Task { await runPull() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(pullConfirmMessage)
            }
            .confirmationDialog(pushConfirmTitle,
                                isPresented: $confirmPushPresented,
                                titleVisibility: .visible) {
                Button("推送", role: .none) {
                    Task { await runGitAction(.push) }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(pushConfirmMessage)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func gitStatusBlock(status: VcsStatusSummary, cwd: String) -> some View {
        VStack(alignment: .leading, spacing: T3Spacing.sm) {
            HStack(spacing: T3Spacing.sm) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(T3Color.textTertiary)
                Text(status.refName ?? "无分支")
                    .font(T3Typography.bodyEmphasis)
                    .foregroundStyle(T3Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: T3Spacing.sm)
                if status.aheadCount > 0 {
                    Label("\(status.aheadCount)", systemImage: "arrow.up")
                        .labelStyle(.titleAndIcon)
                        .font(T3Typography.footnote.weight(.semibold))
                        .foregroundStyle(AppAccent.color(for: accentRaw))
                        .monospacedDigit()
                }
                if status.behindCount > 0 {
                    Label("\(status.behindCount)", systemImage: "arrow.down")
                        .labelStyle(.titleAndIcon)
                        .font(T3Typography.footnote.weight(.semibold))
                        .foregroundStyle(T3Color.warning)
                        .monospacedDigit()
                }
                if status.hasUpstream == false {
                    T3Style.Pill(text: "未设置上游分支",
                                 systemImage: "exclamationmark.triangle.fill",
                                 tint: T3Color.warning,
                                 emphasized: true)
                }
            }
            Text(gitStatusSummaryLine(status))
                .font(T3Typography.footnote)
                .foregroundStyle(gitStatusSummaryTint(status))
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(cwd)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(T3Color.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(T3Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T3Color.surfaceElevated, in: RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous)
                .stroke(T3Color.separator, lineWidth: 0.5)
        )
    }

    private func gitFilesList(status: VcsStatusSummary) -> some View {
        VStack(alignment: .leading, spacing: T3Spacing.sm) {
            HStack(spacing: 4) {
                Text("文件变更")
                    .font(T3Typography.caption)
                    .foregroundStyle(T3Color.textTertiary)
                    .tracking(0.6)
                Spacer()
                Text("\(status.workingTree.files.count)")
                    .font(T3Typography.caption)
                    .foregroundStyle(T3Color.textTertiary)
                    .monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(status.workingTree.files.prefix(60).enumerated()), id: \.offset) { index, file in
                    HStack(spacing: T3Spacing.sm) {
                        Text(file.path)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(T3Color.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if file.insertions > 0 {
                            Text("+\(file.insertions)")
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(T3Color.success)
                                .monospacedDigit()
                        }
                        if file.deletions > 0 {
                            Text("−\(file.deletions)")
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(T3Color.danger)
                                .monospacedDigit()
                        }
                    }
                    .padding(.horizontal, T3Spacing.md)
                    .padding(.vertical, 8)
                    if index < min(status.workingTree.files.count, 60) - 1 {
                        Divider().foregroundStyle(T3Color.separator)
                    }
                }
                if status.workingTree.files.count > 60 {
                    Text("还有 \(status.workingTree.files.count - 60) 个文件…")
                        .font(T3Typography.footnote)
                        .foregroundStyle(T3Color.textTertiary)
                        .padding(.horizontal, T3Spacing.md)
                        .padding(.vertical, 8)
                }
            }
            .background(T3Color.surfaceElevated, in: RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous)
                    .stroke(T3Color.separator, lineWidth: 0.5)
            )
        }
    }

    private func gitActionRow(status: VcsStatusSummary) -> some View {
        HStack(spacing: T3Spacing.sm) {
            Button {
                confirmPullPresented = true
            } label: {
                Label("拉取", systemImage: "arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!canPull(status: status))

            Button {
                commitMessageDraft = ""
                withAnimation(.easeInOut(duration: 0.18)) {
                    commitInlineExpanded = true
                }
            } label: {
                Label("提交", systemImage: "checkmark.seal")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isRunningGitAction || !status.hasWorkingTreeChanges)

            Button {
                confirmPushPresented = true
            } label: {
                Label("推送", systemImage: "arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppAccent.color(for: accentRaw))
            .disabled(!canPush(status: status))
        }
    }

    private func commitInlineEditor(status: VcsStatusSummary) -> some View {
        VStack(alignment: .leading, spacing: T3Spacing.sm) {
            Text("提交说明")
                .font(T3Typography.caption)
                .foregroundStyle(T3Color.textTertiary)
                .tracking(0.6)
            TextField("描述本次变更…", text: $commitMessageDraft, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.plain)
                .padding(T3Spacing.md)
                .background(T3Color.surfaceElevated,
                            in: RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous)
                        .stroke(T3Color.separator, lineWidth: 0.5)
                )
            HStack(spacing: T3Spacing.sm) {
                Button("取消") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        commitInlineExpanded = false
                    }
                    commitMessageDraft = ""
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)

                Button {
                    let message = commitMessageDraft
                    withAnimation(.easeInOut(duration: 0.18)) {
                        commitInlineExpanded = false
                    }
                    Task { await runGitAction(.commit, commitMessage: message) }
                } label: {
                    Label("提交", systemImage: "checkmark.seal.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppAccent.color(for: accentRaw))
                .disabled(commitMessageDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || isRunningGitAction
                          || !status.hasWorkingTreeChanges)
            }
        }
    }

    private func gitToastView(_ toast: GitToastInfo) -> some View {
        let tint = toast.isSuccess ? T3Color.success : T3Color.danger
        let icon = toast.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        return HStack(alignment: .top, spacing: T3Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(T3Typography.footnote.weight(.semibold))
                    .foregroundStyle(T3Color.textPrimary)
                if let detail = toast.detail, !detail.isEmpty {
                    Text(detail)
                        .font(T3Typography.footnote)
                        .foregroundStyle(T3Color.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, T3Spacing.sm)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: T3Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: T3Radius.sm, style: .continuous)
                .stroke(tint.opacity(0.30), lineWidth: 0.5)
        )
        .transition(.opacity)
    }

    private func canPull(status: VcsStatusSummary) -> Bool {
        guard !isRunningGitAction, status.isRepo, status.hasUpstream else { return false }
        return status.behindCount > 0
    }

    private func canPush(status: VcsStatusSummary) -> Bool {
        guard !isRunningGitAction, status.isRepo, status.hasUpstream else { return false }
        return status.aheadCount > 0
    }

    private func gitStatusSummaryLine(_ status: VcsStatusSummary) -> String {
        if status.hasWorkingTreeChanges {
            let count = status.workingTree.files.count

            return "\(count) 个文件  +\(status.workingTree.insertions)  −\(status.workingTree.deletions)"
        }
        if status.hasUpstream == false {
            return "工作区干净 · 未设置上游分支"
        }
        if status.aheadCount == 0 && status.behindCount == 0 {
            return "已是最新"
        }
        var parts: [String] = ["工作区干净"]
        if status.aheadCount > 0 { parts.append("\(status.aheadCount) 个提交待推送") }
        if status.behindCount > 0 { parts.append("\(status.behindCount) 个提交待拉取") }
        return parts.joined(separator: " • ")
    }

    private func gitStatusSummaryTint(_ status: VcsStatusSummary) -> Color {
        if status.hasWorkingTreeChanges { return T3Color.textPrimary }
        if status.behindCount > 0 { return T3Color.warning }
        return T3Color.textSecondary
    }

    private var pullConfirmTitle: String {
        guard let status = gitStatus, status.behindCount > 0 else { return "从上游分支拉取？" }

        return "拉取 \(status.behindCount) 个提交？"
    }

    private var pullConfirmMessage: String {
        let branch = gitStatus?.refName ?? "当前分支"
        return "从上游获取更新并快进合并到\(branch)，保留本地提交。"
    }

    private var pushConfirmTitle: String {
        guard let status = gitStatus, status.aheadCount > 0 else { return "推送到上游分支？" }

        return "推送 \(status.aheadCount) 个提交？"
    }

    private var pushConfirmMessage: String {
        let branch = gitStatus?.refName ?? "当前分支"
        return "将\(branch)上的本地提交推送到上游远程分支。"
    }

    private var resolvedThread: ThreadHeaderView.ThreadDescriptor {
        let title = store.detail?.title ?? threadShell.title
        let selection = store.detail?.modelSelection ?? threadShell.modelSelection
        let model = env.serverConfig?.modelDisplayLabel(selection: selection) ?? selection.model
        let interaction = store.detail?.interactionMode ?? threadShell.interactionMode
        let runtime = store.detail?.runtimeMode ?? threadShell.runtimeMode
        let updated = store.detail?.updatedAt ?? threadShell.updatedAt
        return .init(title: title,
                     model: model,
                     interactionMode: interaction,
                     runtimeMode: runtime,
                     updatedAt: updated)
    }

    private var gitCwd: String? {
        if let path = store.detail?.worktreePath, !path.isEmpty { return path }
        if let path = threadShell.worktreePath, !path.isEmpty { return path }
        return env.threadList.project(id: threadShell.projectId)?.workspaceRoot
    }

    private func renameThread(_ newTitle: String) async {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != store.detail?.title else { return }
        guard let client = env.client else { return }
        do {
            try await client.renameThread(threadId: threadShell.id, title: trimmed)
        } catch {
            await MainActor.run { store.lastError = ChineseLocalization.errorDescription(error) }
        }
    }

    private func archiveThread() {
        guard let client = env.client else { return }
        Task {
            do {
                try await client.archiveThread(threadId: threadShell.id)
                await MainActor.run { dismiss() }
            } catch {
                await MainActor.run { store.lastError = ChineseLocalization.errorDescription(error) }
            }
        }
    }

    private func refreshGitStatus() async {
        guard let client = env.client, let cwd = gitCwd else { return }
        await MainActor.run {
            isRefreshingGitStatus = true
            gitStatusError = nil
        }
        defer { Task { @MainActor in isRefreshingGitStatus = false } }
        do {
            let status = try await client.refreshVcsStatus(cwd: cwd)
            await MainActor.run { gitStatus = status }
        } catch {
            await MainActor.run { gitStatusError = ChineseLocalization.errorDescription(error) }
        }
    }

    private func runPull() async {
        guard let client = env.client, let cwd = gitCwd else { return }
        let beforeBehind = gitStatus?.behindCount ?? 0
        await MainActor.run {
            isRunningGitAction = true
            gitStatusError = nil
        }
        defer { Task { @MainActor in isRunningGitAction = false } }
        do {
            let summary = try await client.vcsPull(cwd: cwd)
            await refreshGitStatus()
            await MainActor.run {
                presentGitToast(.init(
                    title: pullToastTitle(status: summary.status, count: beforeBehind),
                    detail: pullToastDetail(summary: summary),
                    isSuccess: true
                ))
            }
        } catch {
            await MainActor.run {
                gitStatusError = ChineseLocalization.errorDescription(error)
                presentGitToast(.init(title: "拉取失败",
                                      detail: ChineseLocalization.errorDescription(error),
                                      isSuccess: false))
            }
        }
    }

    private func runGitAction(_ action: GitStackedAction, commitMessage: String? = nil) async {
        guard let client = env.client, let cwd = gitCwd else { return }
        await MainActor.run {
            isRunningGitAction = true
            gitStatusError = nil
        }
        defer { Task { @MainActor in isRunningGitAction = false } }
        do {
            let summary = try await client.runGitStackedAction(cwd: cwd, action: action, commitMessage: commitMessage)
            await refreshGitStatus()
            await MainActor.run {
                presentGitToast(.init(title: summary.toastTitle,
                                      detail: summary.toastDescription,
                                      isSuccess: true))
            }
        } catch {
            let label: String
            switch action {
            case .commit: label = "提交失败"
            case .push:   label = "推送失败"
            }
            await MainActor.run {
                gitStatusError = ChineseLocalization.errorDescription(error)
                presentGitToast(.init(title: label,
                                      detail: ChineseLocalization.errorDescription(error),
                                      isSuccess: false))
            }
        }
    }

    private func presentGitToast(_ toast: GitToastInfo) {
        gitToastDismissTask?.cancel()
        withAnimation(.easeInOut(duration: 0.18)) {
            gitToast = toast
        }
        gitToastDismissTask = Task { [toastID = toast.id] in
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if gitToast?.id == toastID {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        gitToast = nil
                    }
                }
            }
        }
    }

    private func pullToastTitle(status: String, count: Int) -> String {
        switch status.lowercased() {
        case "uptodate", "up_to_date", "up-to-date":
            return "已是最新"
        case "fastforward", "fast_forward", "fast-forward":

            return count > 0 ? "已拉取 \(count) 个提交" : "已拉取最新提交"
        default:
            return "拉取完成"
        }
    }

    private func pullToastDetail(summary: VcsPullSummary) -> String? {
        if let upstream = summary.upstreamRef, !upstream.isEmpty {
            return "\(summary.refName) ← \(upstream)"
        }
        return summary.refName
    }

    private func unarchiveThread() {
        guard let client = env.client else { return }
        Task {
            do {
                try await client.unarchiveThread(threadId: threadShell.id)
            } catch {
                await MainActor.run { store.lastError = ChineseLocalization.errorDescription(error) }
            }
        }
    }

    private func deleteThread() {
        guard let client = env.client else { return }
        Task {
            do {
                try await client.deleteThread(threadId: threadShell.id)
                await MainActor.run { dismiss() }
            } catch {
                await MainActor.run { store.lastError = ChineseLocalization.errorDescription(error) }
            }
        }
    }

    private func implementPlan(_ plan: ProposedPlan) async {
        guard !isImplementingPlan else { return }
        await MainActor.run { isImplementingPlan = true }
        defer { Task { @MainActor in isImplementingPlan = false } }
        await store.implementProposedPlan(plan)
    }
}

private struct GitToastInfo: Equatable, Identifiable {
    let id: UUID = UUID()
    let title: String
    let detail: String?
    let isSuccess: Bool
}

// MARK: - Thread Header

struct ThreadHeaderView: View {
    struct ThreadDescriptor {
        let title: String
        let model: String
        let interactionMode: ProviderInteractionMode
        let runtimeMode: RuntimeMode
        let updatedAt: Date
    }

    let thread: ThreadDescriptor
    let project: ProjectShell?
    let session: OrchestrationSession?
    let onBack: () -> Void
    let onRename: () -> Void
    let onSetInteractionMode: (ProviderInteractionMode) -> Void
    let onSetRuntimeMode: (RuntimeMode) -> Void
    let onViewDiffs: () -> Void
    let onArchive: () -> Void
    let onUnarchive: () -> Void
    let onDelete: () -> Void
    let isArchived: Bool
    var onOpenGit: (() -> Void)? = nil
    var gitIndicatorTint: Color? = nil

    @AppStorage("accent") private var accentRaw: String = AppAccent.blue.rawValue
    @State private var confirmDelete: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: T3Spacing.md) {
            topRow
            titleBlock
        }
        .padding(.horizontal, T3Spacing.lg)
        .padding(.top, T3Spacing.md)
        .padding(.bottom, T3Spacing.md)
        .background(T3Color.surfaceGrouped)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(T3Color.separator)
                .frame(height: 0.5)
        }
        .confirmationDialog("删除此会话？",
                            isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("删除", role: .destructive, action: onDelete)
            Button("取消", role: .cancel) {}
        } message: {
            Text("此会话将从桌面服务器永久删除。")
        }
    }

    private var topRow: some View {
        HStack(spacing: T3Spacing.sm) {
            T3Style.ToolbarChip(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(T3Color.textPrimary)
            }

            T3WordmarkLabel()

            Spacer(minLength: T3Spacing.sm)

            sessionStatePill

            if let onOpenGit {
                gitChip(action: onOpenGit)
            }

            actionsMenu
        }
    }

    private func gitChip(action: @escaping () -> Void) -> some View {
        T3Style.ToolbarChip(action: action) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(T3Color.textPrimary)
        }
        .overlay(alignment: .topTrailing) {
            if let tint = gitIndicatorTint {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle().stroke(T3Color.surfaceGrouped, lineWidth: 1.5)
                    )
                    .offset(x: 3, y: -3)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel("Git")
    }

    @ViewBuilder
    private var actionsMenu: some View {
        Menu {
            Button {
                onRename()
            } label: {
                Label("重命名会话", systemImage: "pencil")
            }
            Button {
                onViewDiffs()
            } label: {
                Label("查看变更", systemImage: "doc.text.magnifyingglass")
            }
            if isArchived {
                Button {
                    onUnarchive()
                } label: {
                    Label("取消归档", systemImage: "tray.and.arrow.up")
                }
            } else {
                Button {
                    onArchive()
                } label: {
                    Label("归档", systemImage: "archivebox")
                }
            }
            Divider()
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("删除", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(T3Color.textPrimary)
                .frame(width: 34, height: 34)
                .background(T3Color.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous)
                        .stroke(T3Color.separator, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: T3Spacing.sm) {
            Text(thread.title)
                .font(T3Typography.headline)
                .foregroundStyle(T3Color.textPrimary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .center, spacing: T3Spacing.sm) {
                if let project {
                    Text(project.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(T3Color.textSecondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(T3Color.surfaceElevated,
                                    in: RoundedRectangle(cornerRadius: T3Radius.sm, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: T3Radius.sm, style: .continuous)
                                .stroke(T3Color.separator, lineWidth: 0.5)
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                interactionModeMenu
                    .fixedSize(horizontal: true, vertical: false)
            }

            HStack(spacing: T3Spacing.xs) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accentColor)
                Text(thread.model)
                    .font(T3Typography.footnote)
                    .foregroundStyle(T3Color.textSecondary)
                Text("·")
                    .font(T3Typography.footnote)
                    .foregroundStyle(T3Color.textTertiary)
                runtimeModeMenu
                if let session, session.status == .running {
                    Text("·")
                        .font(T3Typography.footnote)
                        .foregroundStyle(T3Color.textTertiary)
                    Text("运行中")
                        .font(T3Typography.footnote)
                        .foregroundStyle(T3Color.warning)
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var sessionStatePill: some View {
        if let session {
            switch session.status {
            case .running:
                T3Style.Pill(text: "运行中",
                             systemImage: "circle.fill",
                             tint: T3Color.warning,
                             emphasized: true)
            case .error:
                T3Style.Pill(text: "错误",
                             systemImage: "exclamationmark.triangle.fill",
                             tint: T3Color.danger,
                             emphasized: true)
            default:
                EmptyView()
            }
        }
    }

    private var interactionModeMenu: some View {
        Menu {
            Button {
                onSetInteractionMode(.default)
            } label: {
                Label("执行", systemImage: thread.interactionMode == .default ? "checkmark" : "hammer")
            }
            Button {
                onSetInteractionMode(.plan)
            } label: {
                Label("规划", systemImage: thread.interactionMode == .plan ? "checkmark" : "doc.plaintext")
            }
        } label: {
            interactionModeBadge
        }
    }

    private var interactionModeBadge: some View {
        let mode = thread.interactionMode
        let label = mode == .plan ? "规划" : "执行"
        let tint: Color = mode == .plan ? accentColor : T3Color.success
        return T3Style.Pill(text: label, tint: tint, emphasized: true)
    }

    private var runtimeModeMenu: some View {
        Menu {
            Button {
                onSetRuntimeMode(.approvalRequired)
            } label: {
                Label("逐项审批",
                      systemImage: thread.runtimeMode == .approvalRequired ? "checkmark" : "checkmark.shield")
            }
            Button {
                onSetRuntimeMode(.autoAcceptEdits)
            } label: {
                Label("自动编辑",
                      systemImage: thread.runtimeMode == .autoAcceptEdits ? "checkmark" : "wand.and.stars")
            }
            Button {
                onSetRuntimeMode(.fullAccess)
            } label: {
                Label("完全访问",
                      systemImage: thread.runtimeMode == .fullAccess ? "checkmark" : "lock.open")
            }
        } label: {
            HStack(spacing: 3) {
                Text(runtimeModeLabel)
                    .font(T3Typography.footnote)
                    .foregroundStyle(runtimeModeTint)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(T3Color.textTertiary)
            }
        }
    }

    private var runtimeModeLabel: String {
        switch thread.runtimeMode {
        case .approvalRequired: "逐项审批"
        case .autoAcceptEdits: "自动编辑"
        case .fullAccess: "完全访问"
        }
    }

    private var runtimeModeTint: Color {
        switch thread.runtimeMode {
        case .approvalRequired: T3Color.warning
        case .autoAcceptEdits: T3Color.primary
        case .fullAccess: T3Color.success
        }
    }

    private var accentColor: Color {
        AppAccent.color(for: accentRaw)
    }
}

private struct ThreadDiffSheet: View {
    let changes: [ThreadDiffChange]

    var body: some View {
        NavigationStack {
            Group {
                if changes.isEmpty {
                    ContentUnavailableView("暂无文件变更",
                                           systemImage: "doc.text",
                                           description: Text("智能体编辑文件后，变更会显示在这里。"))
                } else {
                    List {
                        ForEach(changes) { change in
                            Section {
                                if let command = change.command, !command.isEmpty {
                                    Text(command)
                                        .font(.system(.footnote, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                                ForEach(change.files, id: \.self) { file in
                                    HStack(spacing: T3Spacing.sm) {
                                        Image(systemName: "doc")
                                            .foregroundStyle(T3Color.textTertiary)
                                        Text(file)
                                            .font(.system(.footnote, design: .monospaced))
                                            .foregroundStyle(T3Color.textPrimary)
                                    }
                                }
                                if let detail = change.detail, !detail.isEmpty {
                                    Text(detail)
                                        .font(T3Typography.footnote)
                                        .foregroundStyle(T3Color.textSecondary)
                                        .textSelection(.enabled)
                                }
                            } header: {
                                Text(change.title)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("变更")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Rename Sheet

private struct ThreadRenameSheet: View {
    @State private var draft: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    init(initial: String,
         onSubmit: @escaping (String) -> Void,
         onCancel: @escaping () -> Void) {
        _draft = State(initialValue: initial)
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: T3Spacing.lg) {
                TextField("会话标题", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { onSubmit(draft) }
                Spacer()
            }
            .padding(T3Spacing.lg)
            .navigationTitle("重命名会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSubmit(draft)
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
    }
}
