import Foundation

enum EffectRPCMessage {
    case request(id: String, tag: String, payload: Any, headers: [[String]])
    case streamRequest(id: String, tag: String, payload: Any, headers: [[String]])
    case interrupt(requestId: String, interruptors: [String])
    case ack(requestId: String)
    case ping
    case eof

    case chunk(requestId: String, values: [Any])
    case exit(requestId: String, success: Bool, value: Any?, errorTag: String?, errorMessage: String?)
    case pong
    case defect(message: String)
    case unknown(json: Any)

    var isOutbound: Bool {
        switch self {
        case .request, .streamRequest, .interrupt, .ack, .ping, .pong, .eof: true
        default: false
        }
    }
}

enum EffectRPCEncoder {
    static func encode(_ message: EffectRPCMessage) throws -> Data {
        try JSONSerialization.data(withJSONObject: encodeOne(message), options: [])
    }

    private static func encodeOne(_ msg: EffectRPCMessage) -> [String: Any] {
        switch msg {
        case let .request(id, tag, payload, headers):
            return ["_tag": "Request", "id": id, "tag": tag,
                    "payload": payload, "headers": headers,
                    "spanId": randomHex(count: 16), "traceId": randomHex(count: 32),
                    "sampled": false]
        case let .streamRequest(id, tag, payload, headers):
            return ["_tag": "Request", "id": id, "tag": tag,
                    "payload": payload, "headers": headers,
                    "spanId": randomHex(count: 16), "traceId": randomHex(count: 32),
                    "sampled": false]
        case let .interrupt(requestId, interruptors):
            return ["_tag": "Interrupt", "requestId": requestId, "interruptors": interruptors]
        case let .ack(requestId):
            return ["_tag": "Ack", "requestId": requestId]
        case .ping:
            return ["_tag": "Ping"]
        case .pong:
            return ["_tag": "Pong"]
        case .eof:
            return ["_tag": "Eof"]
        default:
            return [:]
        }
    }

    private static func randomHex(count: Int) -> String {
        UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
            .prefix(count)
            .description
    }
}

enum EffectRPCDecoder {
    static func decodeFrame(_ data: Data) throws -> [EffectRPCMessage] {
        let raw = try JSONSerialization.jsonObject(with: data)
        if let array = raw as? [Any] {
            return try array.map(decodeOne)
        }
        return [try decodeOne(raw)]
    }

    private static func decodeOne(_ any: Any) throws -> EffectRPCMessage {
        guard let dict = any as? [String: Any], let tag = dict["_tag"] as? String else {
            return .unknown(json: any)
        }
        switch tag {
        case "Ping":
            return .ping
        case "Pong":
            return .pong
        case "Chunk":
            let id = (dict["requestId"] as? String) ?? ""
            let values = (dict["values"] as? [Any]) ?? []
            return .chunk(requestId: id, values: values)
        case "Exit":
            let id = (dict["requestId"] as? String) ?? ""
            let exit = dict["exit"] as? [String: Any] ?? [:]
            let exitTag = exit["_tag"] as? String ?? "Failure"
            if exitTag == "Success" {
                return .exit(requestId: id, success: true, value: exit["value"],
                             errorTag: nil, errorMessage: nil)
            } else {
                let failure = failureDetails(exit["cause"])
                return .exit(requestId: id, success: false, value: nil,
                             errorTag: failure?.tag, errorMessage: failure?.message ?? "服务器错误")
            }
        case "Defect":
            let message = (dict["defect"] as? String) ?? "未知服务器错误"
            return .defect(message: message)
        case "ClientProtocolError":
            let message = (dict["error"] as? String) ?? "客户端协议错误"
            return .defect(message: message)
        default:
            return .unknown(json: any)
        }
    }

    /// Protocol 2 encodes Effect causes as an array; protocol 1 uses a single cause.
    private static func failureDetails(_ value: Any?, depth: Int = 0) -> (tag: String?, message: String)? {
        guard depth < 16 else { return nil }
        if let reasons = value as? [Any] {
            for reason in reasons {
                if let failure = failureDetails(reason, depth: depth + 1) { return failure }
            }
            return nil
        }
        guard let cause = value as? [String: Any] else { return nil }
        for field in ["error", "defect"] {
            if let message = cause[field] as? String, !message.isEmpty { return (nil, message) }
            if let error = cause[field] as? [String: Any],
               let message = (error["message"] as? String) ?? (error["detail"] as? String), !message.isEmpty {
                return (field == "error" ? error["_tag"] as? String : nil, message)
            }
        }
        for field in ["reasons", "left", "right", "cause"] {
            if let failure = failureDetails(cause[field], depth: depth + 1) { return failure }
        }
        return nil
    }
}
