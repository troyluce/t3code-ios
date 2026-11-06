import SwiftUI

private enum ArchivedSortOrder: String, CaseIterable {
    case recent = "最近归档"
    case title = "标题"
    case project = "项目"
}

struct ArchivedThreadsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var actionError: String?
    @State private var pendingDeleteThread: ThreadShell?
    @State private var searchText: String = ""
    @State private var showBulkActionDialog: Bool = false
    @State private var showConfirmBulkDelete: Bool = false
    @State private var showConfirmBulkUnarchive: Bool = false
    @State private var sortOrder: ArchivedSortOrder = .recent

    var body: some View {
        ZStack {
            T3Color.surfaceGrouped.ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar
                    .padding(.horizontal, T3Spacing.lg)
                    .padding(.top, T3Spacing.md)
                    .padding(.bottom, T3Spacing.md)

                if archivedThreads.isEmpty {
                    emptyState
                } else {
                    archivedList
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索已归档会话")
        .alert("更新会话失败",
               isPresented: Binding(get: { actionError != nil },
                                    set: { if !$0 { actionError = nil } })) {
            Button("好", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .confirmationDialog("删除此会话？",
                            isPresented: Binding(get: { pendingDeleteThread != nil },
                                                 set: { if !$0 { pendingDeleteThread = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingDeleteThread) { thread in
            Button("删除", role: .destructive) {
                let target = thread
                pendingDeleteThread = nil
                delete(thread: target)
            }
            Button("取消", role: .cancel) { pendingDeleteThread = nil }
        } message: { _ in
            Text("此会话将从桌面服务器永久删除。")
        }
        .confirmationDialog("批量操作", isPresented: $showBulkActionDialog, titleVisibility: .visible) {
            Button("恢复当前列表中的会话") {
                showConfirmBulkUnarchive = true
            }
            Button("删除当前列表中的会话", role: .destructive) {
                showConfirmBulkDelete = true
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("操作将应用于当前筛选结果中的所有已归档会话。")
        }
        .alert("恢复当前列表中的所有会话？",
               isPresented: $showConfirmBulkUnarchive) {
            Button("取消归档") {
                unarchiveAllVisible()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将恢复 \(archivedThreads.count) 个会话。")
        }
        .alert("删除当前列表中的所有会话？",
               isPresented: $showConfirmBulkDelete) {
            Button("删除", role: .destructive) {
                deleteAllVisible()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将从桌面服务器永久删除 \(archivedThreads.count) 个会话。")
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: T3Spacing.sm) {
            T3Style.ToolbarChip(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(T3Color.textPrimary)
            }
            VStack(alignment: .leading, spacing: 2) {
                T3WordmarkLabel()
                Text("\(archivedThreads.count) 个会话")
                    .font(T3Typography.footnote)
                    .foregroundStyle(T3Color.textTertiary)
            }
            Spacer()
            Menu {
                ForEach(ArchivedSortOrder.allCases, id: \.self) { option in
                    Button {
                        sortOrder = option
                    } label: {
                        if sortOrder == option {
                            Label(option.rawValue, systemImage: "checkmark")
                        } else {
                            Text(option.rawValue)
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(T3Color.textPrimary)
                    .background(T3Color.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous)
                            .stroke(T3Color.separator, lineWidth: 0.5)
                    )
            }
            if !archivedThreads.isEmpty {
                T3Style.ToolbarChip(action: { showBulkActionDialog = true }) {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(T3Color.textPrimary)
                }
            }
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: T3Spacing.md) {
            Spacer()
            Image(systemName: "archivebox")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(T3Color.textTertiary)
                .frame(width: 56, height: 56)
                .background(T3Color.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous)
                        .stroke(T3Color.separator, lineWidth: 0.5)
                )
            Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 ? "暂无已归档会话"
                 : "没有匹配结果")
                .font(T3Typography.title)
            Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 ? "可以在聊天列表中归档会话，方便以后查阅，让当前列表更清晰。"
                 : "请尝试其他关键词，或清除筛选条件。")
                .font(T3Typography.callout)
                .foregroundStyle(T3Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, T3Spacing.xl)
            Spacer()
        }
    }

    // MARK: - List

    private var archivedList: some View {
        List {
            ForEach(archivedGrouped, id: \.0.id) { project, threads in
                Section {
                    ForEach(threads, id: \.id) { thread in
                        NavigationLink {
                            ThreadView(threadShell: thread)
                                .environment(env)
                        } label: {
                            ThreadRow(thread: thread)
                        }
                        .listRowBackground(T3Color.surfaceElevated)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                unarchive(thread: thread)
                            } label: {
                                Label("取消归档", systemImage: "tray.and.arrow.up")
                            }
                            .tint(T3Color.success)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDeleteThread = thread
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button {
                                unarchive(thread: thread)
                            } label: {
                                Label("取消归档", systemImage: "tray.and.arrow.up")
                            }
                            Button(role: .destructive) {
                                pendingDeleteThread = thread
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text(project.title.uppercased())
                        .font(T3Typography.caption)
                        .tracking(0.6)
                        .foregroundStyle(T3Color.textTertiary)
                        .padding(.leading, -T3Spacing.xs)
                }
            }

            if !ungroupedArchived.isEmpty {
                Section {
                    ForEach(ungroupedArchived, id: \.id) { thread in
                        NavigationLink {
                            ThreadView(threadShell: thread)
                                .environment(env)
                        } label: {
                            ThreadRow(thread: thread)
                        }
                        .listRowBackground(T3Color.surfaceElevated)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                unarchive(thread: thread)
                            } label: {
                                Label("取消归档", systemImage: "tray.and.arrow.up")
                            }
                            .tint(T3Color.success)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDeleteThread = thread
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("未知项目")
                        .font(T3Typography.caption)
                        .tracking(0.6)
                        .foregroundStyle(T3Color.textTertiary)
                        .padding(.leading, -T3Spacing.xs)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(T3Color.surfaceGrouped)
    }

    // MARK: - Actions

    private func unarchive(thread: ThreadShell) {
        guard let client = env.client else { return }
        Task {
            do {
                try await client.unarchiveThread(threadId: thread.id)
            } catch {
                await MainActor.run { actionError = ChineseLocalization.errorDescription(error) }
            }
        }
    }

    private func delete(thread: ThreadShell) {
        guard let client = env.client else { return }
        Task {
            do {
                try await client.deleteThread(threadId: thread.id)
            } catch {
                await MainActor.run { actionError = ChineseLocalization.errorDescription(error) }
            }
        }
    }

    private func unarchiveAllVisible() {
        guard let client = env.client else { return }
        let targets = archivedThreads
        Task {
            for thread in targets {
                do {
                    try await client.unarchiveThread(threadId: thread.id)
                } catch {
                    await MainActor.run { actionError = ChineseLocalization.errorDescription(error) }
                    break
                }
            }
        }
    }

    private func deleteAllVisible() {
        guard let client = env.client else { return }
        let targets = archivedThreads
        Task {
            for thread in targets {
                do {
                    try await client.deleteThread(threadId: thread.id)
                } catch {
                    await MainActor.run { actionError = ChineseLocalization.errorDescription(error) }
                    break
                }
            }
        }
    }

    // MARK: - Data

    private var archivedThreads: [ThreadShell] {
        let filtered = env.threadList.threads
            .filter { $0.archivedAt != nil }
            .filter { thread in
                let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !query.isEmpty else { return true }
                let inTitle = thread.title.localizedCaseInsensitiveContains(query)
                let projectTitle = env.threadList.project(id: thread.projectId)?.title ?? ""
                return inTitle || projectTitle.localizedCaseInsensitiveContains(query)
            }
        switch sortOrder {
        case .recent:
            return filtered.sorted { ($0.archivedAt ?? $0.updatedAt) > ($1.archivedAt ?? $1.updatedAt) }
        case .title:
            return filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .project:
            return filtered.sorted {
                let lhsProject = env.threadList.project(id: $0.projectId)?.title ?? ""
                let rhsProject = env.threadList.project(id: $1.projectId)?.title ?? ""
                if lhsProject != rhsProject {
                    return lhsProject.localizedStandardCompare(rhsProject) == .orderedAscending
                }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
    }

    private var archivedGrouped: [(ProjectShell, [ThreadShell])] {
        var byProject: [ProjectID: [ThreadShell]] = [:]
        for thread in archivedThreads { byProject[thread.projectId, default: []].append(thread) }
        return env.threadList.projects.compactMap { project in
            guard let threads = byProject[project.id], !threads.isEmpty else { return nil }
            return (project, threads)
        }
    }

    private var ungroupedArchived: [ThreadShell] {
        let projectIds = Set(env.threadList.projects.map(\.id))
        return archivedThreads.filter { !projectIds.contains($0.projectId) }
    }
}
