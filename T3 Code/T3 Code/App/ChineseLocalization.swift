import Foundation

enum ChineseLocalization {
    static let locale = Locale(identifier: "zh_Hans_CN")

    static func errorDescription(_ error: Error) -> String {
        if error is DecodingError {
            return "无法解析服务器响应，请检查客户端与服务器版本是否匹配。"
        }
        let details = error as NSError
        guard details.domain == NSURLErrorDomain else {
            return error.localizedDescription
        }
        switch details.code {
        case NSURLErrorNotConnectedToInternet:
            return "网络未连接，请检查网络设置。"
        case NSURLErrorTimedOut:
            return "连接超时，请检查服务器地址和网络后重试。"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "找不到服务器，请检查服务器地址。"
        case NSURLErrorCannotConnectToHost:
            return "无法连接服务器，请确认桌面端已启动并开启网络访问。"
        case NSURLErrorNetworkConnectionLost:
            return "网络连接已中断，请重新连接。"
        case NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid:
            return "无法建立安全连接，请检查服务器的 HTTPS 证书。"
        case NSURLErrorBadURL, NSURLErrorUnsupportedURL:
            return "服务器地址格式无效，请使用 HTTP 或 HTTPS 地址。"
        case NSURLErrorUserAuthenticationRequired:
            return "服务器要求身份认证，请重新配对。"
        case NSURLErrorCancelled:
            return "操作已取消。"
        default:
            return "网络请求失败（错误代码 \(details.code)）。"
        }
    }
}
