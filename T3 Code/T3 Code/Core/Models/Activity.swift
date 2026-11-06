import Foundation

struct ApprovalRequestID: Codable, Hashable, RawRepresentable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

enum ApprovalRequestKind: String, Codable, Sendable {
    case command
    case fileRead = "file-read"
    case fileChange = "file-change"

    var displayLabel: String {
        switch self {
        case .command: "执行命令"
        case .fileRead: "读取文件"
        case .fileChange: "修改文件"
        }
    }

    var systemImage: String {
        switch self {
        case .command: "terminal"
        case .fileRead: "doc.text.magnifyingglass"
        case .fileChange: "pencil.and.outline"
        }
    }
}

enum ApprovalDecision: String, Codable, Sendable {
    case accept
    case acceptForSession
    case decline
    case cancel

    var label: String {
        switch self {
        case .accept: "允许"
        case .acceptForSession: "本次会话始终允许"
        case .decline: "拒绝"
        case .cancel: "取消"
        }
    }
}

struct PendingApproval: Identifiable, Hashable, Sendable {
    let requestId: ApprovalRequestID
    let kind: ApprovalRequestKind
    let detail: String?
    let createdAt: Date

    var id: ApprovalRequestID { requestId }
}

struct UserInputOption: Hashable, Sendable {
    let label: String
    let description: String
}

struct UserInputQuestion: Identifiable, Hashable, Sendable {
    let id: String
    let header: String
    let question: String
    let options: [UserInputOption]
    let multiSelect: Bool
}

struct PendingUserInput: Identifiable, Hashable, Sendable {
    let requestId: ApprovalRequestID
    let questions: [UserInputQuestion]
    let createdAt: Date

    var id: ApprovalRequestID { requestId }
}

struct ProposedPlan: Identifiable, Hashable, Sendable {
    let id: String
    let turnId: TurnID?
    let planMarkdown: String
    let implementedAt: Date?
    let implementationThreadId: ThreadID?
    let createdAt: Date
    let updatedAt: Date

    var isImplementable: Bool {
        implementedAt == nil
    }
}

struct ThreadActivity: Identifiable, Hashable, Sendable {
    let id: String
    let kind: String
    let tone: String
    let summary: String
    let turnId: TurnID?
    let createdAt: Date
    let payload: [String: AnyCodable]?

    static func == (lhs: ThreadActivity, rhs: ThreadActivity) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.summary == rhs.summary
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(kind)
    }

    var requestId: ApprovalRequestID? {
        payload?["requestId"].stringValue.map(ApprovalRequestID.init(rawValue:))
    }

    var requestKind: ApprovalRequestKind? {
        if let raw = payload?["requestKind"].stringValue,
           let kind = ApprovalRequestKind(rawValue: raw) {
            return kind
        }
        switch payload?["requestType"].stringValue {
        case "command_execution_approval", "exec_command_approval", "dynamic_tool_call":
            return .command
        case "file_read_approval":
            return .fileRead
        case "file_change_approval", "apply_patch_approval":
            return .fileChange
        default:
            return nil
        }
    }

    var detail: String? {
        guard let value = payload?["detail"].stringValue, !value.isEmpty else { return nil }
        return value
    }

    var userInputQuestions: [UserInputQuestion]? {
        guard let rawQuestions = payload?["questions"].arrayValue else { return nil }
        let parsed: [UserInputQuestion] = rawQuestions.compactMap { entry in
            guard let dict = entry.objectValue,
                  let id = dict["id"].stringValue,
                  let header = dict["header"].stringValue,
                  let question = dict["question"].stringValue,
                  let rawOptions = dict["options"].arrayValue else { return nil }
            let options: [UserInputOption] = rawOptions.compactMap { rawOption in
                guard let option = rawOption.objectValue,
                      let label = option["label"].stringValue,
                      let description = option["description"].stringValue else { return nil }
                return UserInputOption(label: label, description: description)
            }
            guard !options.isEmpty else { return nil }
            let multi = dict["multiSelect"].boolValue ?? false
            return UserInputQuestion(
                id: id,
                header: header,
                question: question,
                options: options,
                multiSelect: multi
            )
        }
        return parsed.isEmpty ? nil : parsed
    }
}

/// Type-erased JSON value used for payloads on activities.
struct AnyCodable: Hashable, Sendable {
    enum Value: Hashable, Sendable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case null
        case array([AnyCodable])
        case object([String: AnyCodable])
    }

    let value: Value

    init(_ value: Value) {
        self.value = value
    }

    static func from(any: Any?) -> AnyCodable {
        switch any {
        case nil:
            return AnyCodable(.null)
        case let bool as Bool:
            return AnyCodable(.bool(bool))
        case let number as NSNumber:
            // Distinguish bool from number.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return AnyCodable(.bool(number.boolValue))
            }
            return AnyCodable(.number(number.doubleValue))
        case let string as String:
            return AnyCodable(.string(string))
        case let array as [Any]:
            return AnyCodable(.array(array.map { AnyCodable.from(any: $0) }))
        case let dict as [String: Any]:
            var out: [String: AnyCodable] = [:]
            for (key, value) in dict {
                out[key] = AnyCodable.from(any: value)
            }
            return AnyCodable(.object(out))
        case is NSNull:
            return AnyCodable(.null)
        default:
            return AnyCodable(.null)
        }
    }
}

extension Optional where Wrapped == AnyCodable {
    var stringValue: String? {
        guard let wrapped = self, case let .string(value) = wrapped.value else { return nil }
        return value
    }

    var doubleValue: Double? {
        guard let wrapped = self, case let .number(value) = wrapped.value else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard let wrapped = self, case let .bool(value) = wrapped.value else { return nil }
        return value
    }

    var arrayValue: [AnyCodable]? {
        guard let wrapped = self, case let .array(value) = wrapped.value else { return nil }
        return value
    }

    var objectValue: [String: AnyCodable]? {
        guard let wrapped = self, case let .object(value) = wrapped.value else { return nil }
        return value
    }
}

extension AnyCodable {
    var stringValue: String? {
        if case let .string(value) = value { return value }
        return nil
    }

    var arrayValue: [AnyCodable]? {
        if case let .array(value) = value { return value }
        return nil
    }

    var objectValue: [String: AnyCodable]? {
        if case let .object(value) = value { return value }
        return nil
    }
}

extension ThreadActivity {
    nonisolated static func decode(from dict: [String: Any]) -> ThreadActivity? {
        guard let id = dict["id"] as? String,
              let kind = dict["kind"] as? String,
              let summary = dict["summary"] as? String,
              let createdAtRaw = dict["createdAt"] as? String,
              let createdAt = ISO8601Decoder.parse(createdAtRaw) else { return nil }
        let tone = (dict["tone"] as? String) ?? "info"
        let turnId = (dict["turnId"] as? String).map { TurnID(rawValue: $0) }
        let payloadRaw = dict["payload"]
        let payload: [String: AnyCodable]?
        if case let .object(map) = AnyCodable.from(any: payloadRaw).value {
            payload = map
        } else {
            payload = nil
        }
        return ThreadActivity(
            id: id,
            kind: kind,
            tone: tone,
            summary: summary,
            turnId: turnId,
            createdAt: createdAt,
            payload: payload
        )
    }
}

extension ProposedPlan {
    nonisolated static func decode(from dict: [String: Any]) -> ProposedPlan? {
        guard let id = dict["id"] as? String,
              let planMarkdown = dict["planMarkdown"] as? String,
              let createdAtRaw = dict["createdAt"] as? String,
              let createdAt = ISO8601Decoder.parse(createdAtRaw),
              let updatedAtRaw = dict["updatedAt"] as? String,
              let updatedAt = ISO8601Decoder.parse(updatedAtRaw) else { return nil }
        let turnId = (dict["turnId"] as? String).map { TurnID(rawValue: $0) }
        let implementedAt = (dict["implementedAt"] as? String).flatMap(ISO8601Decoder.parse)
        let implementationThreadId = (dict["implementationThreadId"] as? String)
            .map { ThreadID(rawValue: $0) }
        return ProposedPlan(
            id: id,
            turnId: turnId,
            planMarkdown: planMarkdown,
            implementedAt: implementedAt,
            implementationThreadId: implementationThreadId,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

enum PendingDerivation {
    /// Folds activity history into the open pending approvals.
    static func pendingApprovals(from activities: [ThreadActivity]) -> [PendingApproval] {
        var open: [ApprovalRequestID: PendingApproval] = [:]
        let ordered = activities.sorted(by: activityOrder)
        for activity in ordered {
            guard let requestId = activity.requestId else { continue }
            switch activity.kind {
            case "approval.requested":
                guard let kind = activity.requestKind else { continue }
                open[requestId] = PendingApproval(
                    requestId: requestId,
                    kind: kind,
                    detail: activity.detail,
                    createdAt: activity.createdAt
                )
            case "approval.resolved":
                open.removeValue(forKey: requestId)
            case "provider.approval.respond.failed":
                if isStaleFailure(detail: activity.detail) {
                    open.removeValue(forKey: requestId)
                }
            default:
                continue
            }
        }
        return open.values.sorted { $0.createdAt < $1.createdAt }
    }

    /// Folds activity history into the open pending user-input requests.
    static func pendingUserInputs(from activities: [ThreadActivity]) -> [PendingUserInput] {
        var open: [ApprovalRequestID: PendingUserInput] = [:]
        let ordered = activities.sorted(by: activityOrder)
        for activity in ordered {
            guard let requestId = activity.requestId else { continue }
            switch activity.kind {
            case "user-input.requested":
                guard let questions = activity.userInputQuestions else { continue }
                open[requestId] = PendingUserInput(
                    requestId: requestId,
                    questions: questions,
                    createdAt: activity.createdAt
                )
            case "user-input.resolved":
                open.removeValue(forKey: requestId)
            case "provider.user-input.respond.failed":
                if isStaleFailure(detail: activity.detail) {
                    open.removeValue(forKey: requestId)
                }
            default:
                continue
            }
        }
        return open.values.sorted { $0.createdAt < $1.createdAt }
    }

    private static func activityOrder(lhs: ThreadActivity, rhs: ThreadActivity) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id < rhs.id
    }

    private static func isStaleFailure(detail: String?) -> Bool {
        guard let detail = detail?.lowercased() else { return false }
        return detail.contains("stale pending approval request")
            || detail.contains("stale pending user-input request")
            || detail.contains("unknown pending approval request")
            || detail.contains("unknown pending permission request")
            || detail.contains("unknown pending user-input request")
    }
}
