import Foundation

struct PairingResult: Sendable {
    let bearerToken: String
}

enum PairingFlow {
    struct WebSocketToken: Sendable {
        let token: String
        let parameterName: String
    }

    static func fetchEnvironment(serverURL: URL) async throws -> EnvironmentDescriptor {
        var request = URLRequest(url: serverBaseURL(from: serverURL).appendingPathComponent(".well-known/t3/environment"))
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw T3Error.pairingFailed("无法读取 T3 Code 服务器环境信息。")
        }
        guard let descriptor = EnvironmentDescriptor.decodeLenient(data) else {
            throw T3Error.pairingFailed("此地址未返回有效的 T3 Code 服务器信息。")
        }
        return descriptor
    }

    static func exchangeToken(serverURL: URL, oneTimeToken: String) async throws -> PairingResult {
        var request = URLRequest(url: serverBaseURL(from: serverURL).appendingPathComponent("oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "urn:ietf:params:oauth:grant-type:token-exchange"),
            URLQueryItem(name: "subject_token", value: oneTimeToken),
            URLQueryItem(name: "subject_token_type", value: "urn:t3:params:oauth:token-type:environment-bootstrap"),
            URLQueryItem(name: "requested_token_type", value: "urn:ietf:params:oauth:token-type:access_token"),
            URLQueryItem(name: "client_label", value: "T3 Code iOS 中文版"),
            URLQueryItem(name: "client_device_type", value: "mobile"),
            URLQueryItem(name: "client_os", value: "iOS")
        ]
        request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw T3Error.pairingFailed("服务器没有响应") }
        if http.statusCode == 404 || http.statusCode == 405 {
            return try await exchangeLegacyToken(serverURL: serverURL, oneTimeToken: oneTimeToken)
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw T3Error.pairingFailed("配对链接已失效或已被使用，请在桌面端重新生成。")
        }
        guard (200...299).contains(http.statusCode) else {
            throw T3Error.pairingFailed("配对失败（状态码 \(http.statusCode)）：\(errorMessage(from: data))")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String, !token.isEmpty,
              (json["token_type"] as? String)?.lowercased() == "bearer" else {
            throw T3Error.pairingFailed("服务器未返回有效的 Bearer 登录令牌。")
        }
        return PairingResult(bearerToken: token)
    }

    static func issueWebSocketToken(serverURL: URL, bearerToken: String) async throws -> WebSocketToken {
        for endpoint in ["api/auth/websocket-ticket/rpc", "api/auth/websocket-ticket", "api/auth/ws-token"] {
            var request = URLRequest(url: serverBaseURL(from: serverURL).appendingPathComponent(endpoint))
            request.httpMethod = "POST"
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw T3Error.pairingFailed("服务器没有响应") }
            if http.statusCode == 404 || http.statusCode == 405 { continue }
            guard (200...299).contains(http.statusCode) else {
                throw T3Error.pairingFailed("获取 WebSocket 票据失败（状态码 \(http.statusCode)）：\(errorMessage(from: data))")
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = (json["ticket"] ?? json["token"]) as? String, !token.isEmpty else {
                throw T3Error.pairingFailed("WebSocket 票据响应无效")
            }
            return WebSocketToken(token: token, parameterName: endpoint.hasSuffix("ws-token") ? "wsToken" : "wsTicket")
        }
        throw T3Error.pairingFailed("服务器未提供兼容的 WebSocket 认证接口，请检查桌面端版本。")
    }

    static func webSocketURL(serverURL: URL, authorization: WebSocketToken?, protocolVersion: Int) throws -> URL {
        guard var components = URLComponents(url: serverBaseURL(from: serverURL), resolvingAgainstBaseURL: false) else { throw T3Error.invalidServerURL }
        switch components.scheme?.lowercased() {
        case "https", "wss": components.scheme = "wss"
        case "http", "ws": components.scheme = "ws"
        default: throw T3Error.invalidServerURL
        }
        components.path = "/ws"
        var items: [URLQueryItem] = []
        if protocolVersion >= 2 { items.append(URLQueryItem(name: "orchestrationProtocol", value: String(protocolVersion))) }
        if let authorization { items.append(URLQueryItem(name: authorization.parameterName, value: authorization.token)) }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { throw T3Error.invalidServerURL }
        return url
    }

    private static func exchangeLegacyToken(serverURL: URL, oneTimeToken: String) async throws -> PairingResult {
        var request = URLRequest(url: serverBaseURL(from: serverURL).appendingPathComponent("api/auth/bootstrap/bearer"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["credential": oneTimeToken])
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw T3Error.pairingFailed("旧版配对接口不可用，请检查桌面端版本并重新生成配对链接。")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = (json["sessionToken"] ?? json["token"] ?? json["bearer"]) as? String, !token.isEmpty else {
            throw T3Error.pairingFailed("配对响应中缺少登录令牌")
        }
        return PairingResult(bearerToken: token)
    }

    static func parsePairingURL(_ raw: String) -> (serverURL: URL, token: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let comps = URLComponents(string: trimmed) else { return nil }

        if let host = comps.queryItems?.first(where: { $0.name == "host" })?.value,
           let backend = URL(string: host),
           let token = parseToken(from: comps) {
            return (serverBaseURL(from: backend), token)
        }

        if let token = parseToken(from: comps),
           let scheme = comps.scheme, let host = comps.host {
            var direct = URLComponents()
            direct.scheme = scheme
            direct.host = host
            direct.port = comps.port
            return direct.url.map { ($0, token) }
        }
        return nil
    }

    static func serverBaseURL(from url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        comps.path = ""
        comps.query = nil
        comps.fragment = nil
        return comps.url ?? url
    }

    private static func parseToken(from comps: URLComponents) -> String? {
        if let token = parseTokenFromFragment(comps.fragment) {
            return token
        }
        return comps.queryItems?.first(where: { $0.name == "token" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseTokenFromFragment(_ fragment: String?) -> String? {
        guard let fragment,
              let comps = URLComponents(string: "?\(fragment)"),
              let token = comps.queryItems?.first(where: { $0.name == "token" })?.value?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return token
    }

    private static func errorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = (json["error_description"] ?? json["message"] ?? json["reason"] ?? json["error"]) as? String,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(message.prefix(300))
        }
        if let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return String(text.prefix(300))
        }
        return "响应为空"
    }
}
