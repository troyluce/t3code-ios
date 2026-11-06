import Foundation
import Observation

struct ThreadDiffChange: Identifiable, Hashable {
    let id: String
    let title: String
    let command: String?
    let detail: String?
    let files: [String]
    let createdAt: Date
}

@Observable
final class ThreadStore {
    let threadId: ThreadID
    var detail: ThreadDetail?
    var messages: [Message] = []
    var session: OrchestrationSession?
    var proposedPlans: [ProposedPlan] = []
    var activities: [ThreadActivity] = []
    var pendingApprovals: [PendingApproval] = []
    var pendingUserInputs: [PendingUserInput] = []
    var lastError: String?
    var isSending: Bool = false

    private var subscription: StreamSubscription?
    private weak var client: T3Client?

    init(threadId: ThreadID) {
        self.threadId = threadId
    }

    func start(client: T3Client) async {
        self.client = client
        subscription = try? await client.subscribeThread(threadId: threadId) { item in
            Task { @MainActor [weak self] in
                self?.handle(item: item)
            }
        }
    }

    func stop() async {
        if let sub = subscription { await sub.cancel() }
        subscription = nil
    }

    var latestProposedPlan: ProposedPlan? {
        let sortedPlans = proposedPlans.sorted { $0.updatedAt < $1.updatedAt }
        guard let plan = sortedPlans.last else { return nil }
        guard plan.implementedAt == nil else { return nil }
        return plan
    }

    var isTurnRunning: Bool {
        if let session, session.status == .running { return true }
        if let state = detail?.latestTurn?.state, state == .running { return true }
        return isSending
    }

    var diffChanges: [ThreadDiffChange] {
        let rendered = RenderableActivity.collapse(activities)
        return rendered
            .filter { !$0.changedFiles.isEmpty }
            .map {
                ThreadDiffChange(
                    id: $0.id,
                    title: $0.title,
                    command: $0.command,
                    detail: $0.detail,
                    files: $0.changedFiles,
                    createdAt: $0.createdAt
                )
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func sendMessage(text: String,
                     attachments: [UploadImage],
                     fallbackModelSelection: ModelSelection?) async {
        guard let client else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty else { return }

        let resolvedSelection = detail?.modelSelection ?? fallbackModelSelection
        guard let modelSelection = resolvedSelection else {
            await MainActor.run { self.lastError = "尚未选择模型" }
            return
        }

        await MainActor.run { self.isSending = true }
        defer { Task { @MainActor in self.isSending = false } }

        do {
            try await client.dispatchTurnStart(
                threadId: threadId,
                text: text,
                attachments: attachments,
                modelSelection: modelSelection,
                runtimeMode: detail?.runtimeMode ?? .fullAccess,
                interactionMode: detail?.interactionMode ?? .default
            )
        } catch {
            await MainActor.run { self.lastError = ChineseLocalization.errorDescription(error) }
        }
    }

    func interruptTurn() async {
        guard let client else { return }
        do {
            try await client.interruptTurn(threadId: threadId,
                                           turnId: detail?.latestTurn?.turnId)
        } catch {
            await MainActor.run { self.lastError = ChineseLocalization.errorDescription(error) }
        }
    }

    func respondApproval(_ approval: PendingApproval, decision: ApprovalDecision) async {
        guard let client else { return }
        await MainActor.run {
            self.pendingApprovals.removeAll { $0.requestId == approval.requestId }
        }
        do {
            try await client.respondApproval(threadId: threadId,
                                             requestId: approval.requestId,
                                             decision: decision)
        } catch {
            await MainActor.run { self.lastError = ChineseLocalization.errorDescription(error) }
        }
    }

    func respondUserInput(_ input: PendingUserInput,
                          answers: [String: Any]) async {
        guard let client else { return }
        await MainActor.run {
            self.pendingUserInputs.removeAll { $0.requestId == input.requestId }
        }
        do {
            try await client.respondUserInput(threadId: threadId,
                                              requestId: input.requestId,
                                              answers: answers)
        } catch {
            await MainActor.run { self.lastError = ChineseLocalization.errorDescription(error) }
        }
    }

    func setInteractionMode(_ mode: ProviderInteractionMode) async {
        guard let client, detail?.interactionMode != mode else { return }
        do {
            try await client.setInteractionMode(threadId: threadId, mode: mode)
        } catch {
            await MainActor.run { self.lastError = ChineseLocalization.errorDescription(error) }
        }
    }

    func setRuntimeMode(_ mode: RuntimeMode) async {
        guard let client, detail?.runtimeMode != mode else { return }
        do {
            try await client.setRuntimeMode(threadId: threadId, mode: mode)
        } catch {
            await MainActor.run { self.lastError = ChineseLocalization.errorDescription(error) }
        }
    }

    func updateModelSelection(_ selection: ModelSelection) async {
        await MainActor.run {
            if var detail = self.detail {
                detail.modelSelection = selection
                self.detail = detail
            }
        }
        guard let client else { return }
        do {
            try await client.updateThreadModelSelection(threadId: threadId,
                                                        modelSelection: selection)
        } catch {
            await MainActor.run { self.lastError = ChineseLocalization.errorDescription(error) }
        }
    }

    func implementProposedPlan(_ plan: ProposedPlan) async {
        guard let client, let detail else { return }
        do {
            try await client.startTurnFromProposedPlan(
                threadId: threadId,
                planId: plan.id,
                sourceThreadId: threadId,
                modelSelection: detail.modelSelection,
                runtimeMode: detail.runtimeMode,
                interactionMode: .default
            )
        } catch {
            await MainActor.run { self.lastError = ChineseLocalization.errorDescription(error) }
        }
    }

    @MainActor
    private func handle(item: ThreadStreamItem) {
        switch item {
        case .snapshot(let detail, _):
            self.detail = detail
            self.messages = detail.messages.sorted { $0.createdAt < $1.createdAt }
            self.session = detail.session
            self.proposedPlans = detail.proposedPlans
            self.activities = detail.activities
            recomputePending()
        case .event(let event):
            apply(event)
        }
    }

    @MainActor
    private func apply(_ event: ThreadEvent) {
        switch event.type {
        case "thread.message-sent":
            applyMessageSent(event)
        case "thread.session-set":
            if let sessionDict = event.payload["session"] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: sessionDict),
               let session = try? JSONDecoder().decode(OrchestrationSession.self, from: data) {
                self.session = session
                if var detail = self.detail {
                    detail.session = session
                    self.detail = detail
                }
            }
        case "thread.meta-updated":
            applyMetaUpdated(event)
        case "thread.runtime-mode-set":
            if let raw = event.payload["runtimeMode"] as? String,
               let mode = RuntimeMode(rawValue: raw),
               var detail = self.detail {
                detail.runtimeMode = mode
                self.detail = detail
            }
        case "thread.interaction-mode-set":
            if let raw = event.payload["interactionMode"] as? String,
               let mode = ProviderInteractionMode(rawValue: raw),
               var detail = self.detail {
                detail.interactionMode = mode
                self.detail = detail
            }
        case "thread.archived":
            if var detail = self.detail {
                detail.archivedAt = (event.payload["archivedAt"] as? String).flatMap(ISO8601Decoder.parse) ?? Date()
                self.detail = detail
            }
        case "thread.unarchived":
            if var detail = self.detail {
                detail.archivedAt = nil
                self.detail = detail
            }
        case "thread.activity-appended":
            if let activityDict = event.payload["activity"] as? [String: Any],
               let activity = ThreadActivity.decode(from: activityDict) {
                upsertActivity(activity)
                recomputePending()
            }
        case "thread.proposed-plan-upserted":
            if let planDict = event.payload["proposedPlan"] as? [String: Any],
               let plan = ProposedPlan.decode(from: planDict) {
                if let i = proposedPlans.firstIndex(where: { $0.id == plan.id }) {
                    proposedPlans[i] = plan
                } else {
                    proposedPlans.append(plan)
                }
                if var detail = self.detail {
                    if let i = detail.proposedPlans.firstIndex(where: { $0.id == plan.id }) {
                        detail.proposedPlans[i] = plan
                    } else {
                        detail.proposedPlans.append(plan)
                    }
                    self.detail = detail
                }
            }
        default:
            break
        }
    }

    @MainActor
    private func applyMessageSent(_ event: ThreadEvent) {
        let fields = mergedThreadMessageFields(event)
        guard let messageIdRaw = (fields["messageId"] as? String) ?? (fields["id"] as? String),
              let roleRaw = fields["role"] as? String,
              let role = MessageRole(rawValue: roleRaw) else { return }
        let payloadText = (fields["text"] as? String) ?? ""
        let createdAt = (fields["createdAt"] as? String).flatMap(ISO8601Decoder.parse) ?? Date()
        let updatedAt = (fields["updatedAt"] as? String).flatMap(ISO8601Decoder.parse) ?? createdAt
        let streaming = (fields["streaming"] as? Bool) ?? false
        let turnId = (fields["turnId"] as? String).map { TurnID(rawValue: $0) }
        let id = MessageID(rawValue: messageIdRaw)
        let attachments = attachmentsFromMessagePayload(fields)

        // Mirror the desktop store semantics: when an existing message
        // receives a streaming event, the payload's text field is the new
        // delta to append. The completion event arrives with streaming=false
        // and text="" — keep the existing accumulated text in that case.
        if let i = messages.firstIndex(where: { $0.id == id }) {
            if streaming {
                messages[i].text += payloadText
            } else if !payloadText.isEmpty {
                messages[i].text = payloadText
            }
            messages[i].streaming = streaming
            messages[i].updatedAt = updatedAt
            if let attachments, !attachments.isEmpty {
                messages[i].attachments = attachments
            }
        } else {
            let msg = Message(id: id, role: role, text: payloadText,
                              attachments: attachments, turnId: turnId,
                              streaming: streaming, createdAt: createdAt,
                              updatedAt: updatedAt)
            messages.append(msg)
            messages.sort { $0.createdAt < $1.createdAt }
        }
    }

    /// Merges top-level event payload with nested `message` object when present.
    private func mergedThreadMessageFields(_ event: ThreadEvent) -> [String: Any] {
        var m = event.payload
        if let inner = event.payload["message"] as? [String: Any] {
            for (k, v) in inner { m[k] = v }
        }
        return m
    }

    private func attachmentsFromMessagePayload(_ fields: [String: Any]) -> [ChatImageAttachment]? {
        guard let raw = fields["attachments"] as? [[String: Any]], !raw.isEmpty else { return nil }
        let parsed = raw.compactMap { ChatImageAttachment(dictionary: $0) }
        return parsed.isEmpty ? nil : parsed
    }

    @MainActor
    private func applyMetaUpdated(_ event: ThreadEvent) {
        guard var detail = self.detail else { return }
        if let title = event.payload["title"] as? String {
            detail.title = title
        }
        if let modelDict = event.payload["modelSelection"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: modelDict),
           let selection = try? JSONDecoder().decode(ModelSelection.self, from: data) {
            detail.modelSelection = selection
        }
        if let branch = event.payload["branch"] as? String {
            detail.branch = branch
        } else if event.payload["branch"] is NSNull {
            detail.branch = nil
        }
        self.detail = detail
    }

    @MainActor
    private func upsertActivity(_ activity: ThreadActivity) {
        if let i = activities.firstIndex(where: { $0.id == activity.id }) {
            activities[i] = activity
        } else {
            activities.append(activity)
        }
        if var detail = self.detail {
            if let i = detail.activities.firstIndex(where: { $0.id == activity.id }) {
                detail.activities[i] = activity
            } else {
                detail.activities.append(activity)
            }
            self.detail = detail
        }
    }

    @MainActor
    private func recomputePending() {
        pendingApprovals = PendingDerivation.pendingApprovals(from: activities)
        pendingUserInputs = PendingDerivation.pendingUserInputs(from: activities)
    }
}

extension Array where Element == Message {
    func mostRecentAssistantText() -> String? {
        last { $0.role == .assistant }?.text
    }
}
