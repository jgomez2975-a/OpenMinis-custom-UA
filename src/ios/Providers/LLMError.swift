import Foundation

enum LLMError: LocalizedError {
    case invalidAPIKey(detail: String = "")
    case networkError(underlying: Error)
    case providerError(message: String)
    /// Transient server-side errors (HTTP 500/502/503/504/529) that should be
    /// retried on the same model rather than triggering a group fallback.
    case transientError(message: String)
    case decodingError(underlying: Error)
    case rateLimited
    case cancelled
    case unknown(underlying: Error?)

    /// HTTP statuses that are normally emitted by an overloaded origin,
    /// reverse proxy, CDN, or gateway and are safe to retry idempotently.
    /// Includes Cloudflare's non-standard 52x family in addition to the common
    /// 5xx responses.
    static let transientHTTPStatusCodes: Set<Int> = [408, 425, 500, 502, 503, 504, 520, 521, 522, 523, 524, 529]

    /// Build a consistently classified and user-safe HTTP error. Proxy failures
    /// often return an entire HTML error page; never surface that markup in the
    /// chat bubble. JSON API messages remain useful and are preserved.
    static func fromHTTP(statusCode: Int, body: String, service: String? = nil) -> LLMError {
        let prefix = service.map { "\($0) " } ?? ""
        if statusCode == 401 || statusCode == 403 {
            return .invalidAPIKey(detail: "\(prefix)HTTP \(statusCode): \(sanitizedHTTPBody(body))")
        }
        if statusCode == 429 { return .rateLimited }

        let message = "\(prefix)HTTP \(statusCode): \(sanitizedHTTPBody(body))"
        if transientHTTPStatusCodes.contains(statusCode) {
            return .transientError(message: message)
        }
        return .providerError(message: message)
    }

    private static func sanitizedHTTPBody(_ body: String, limit: Int = 300) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "empty response" }

        // Prefer structured API error messages when available.
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any],
               let message = error["message"] as? String, !message.isEmpty {
                return String(message.prefix(limit))
            }
            if let message = object["message"] as? String, !message.isEmpty {
                return String(message.prefix(limit))
            }
        }

        let lower = trimmed.lowercased()
        if lower.contains("<!doctype html") || lower.contains("<html") || lower.contains("cloudflare") {
            return "gateway returned an HTML error page"
        }

        // Collapse control characters/newlines so an upstream diagnostic cannot
        // flood or distort the message UI.
        let oneLine = trimmed
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(oneLine.prefix(limit))
    }

    private static func localizedDetail(_ text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("service temporarily unavailable") || lower.contains("temporarily unavailable") {
            return "服务暂时不可用"
        }
        if lower.contains("gateway returned an html error page") {
            return "网关返回了错误页面"
        }
        if lower.contains("request timed out") || lower.contains("timed out") || lower.contains("timeout") {
            return "请求超时"
        }
        if lower.contains("empty response") {
            return "服务器返回空响应"
        }
        if lower.contains("connection reset") {
            return "连接被服务器重置"
        }
        if lower.contains("connection refused") {
            return "服务器拒绝了连接"
        }
        return text
    }

    private static func localizedNetworkError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut: return "请求超时"
            case NSURLErrorNotConnectedToInternet: return "当前没有网络连接"
            case NSURLErrorCannotConnectToHost: return "无法连接到服务器"
            case NSURLErrorNetworkConnectionLost: return "网络连接中断"
            case NSURLErrorDNSLookupFailed: return "域名解析失败"
            case NSURLErrorSecureConnectionFailed: return "安全连接失败"
            default: break
            }
        }
        return localizedDetail(error.localizedDescription)
    }

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey(let detail):
            return detail.isEmpty ? "API 密钥无效" : "API 密钥无效：\(Self.localizedDetail(detail))"
        case .networkError(let error):
            return "网络错误：\(Self.localizedNetworkError(error))"
        case .providerError(let message):
            return "服务商错误：\(Self.localizedDetail(message))"
        case .transientError(let message):
            return "服务暂时不可用：\(Self.localizedDetail(message))"
        case .decodingError(let error):
            return "响应解析失败：\(Self.localizedDetail(error.localizedDescription))"
        case .rateLimited:
            return "请求过于频繁，请稍后再试"
        case .cancelled:
            return "请求已取消"
        case .unknown(let error):
            return "未知错误：\(error.map { Self.localizedDetail($0.localizedDescription) } ?? "暂无详细信息")"
        }
    }

    var isNetworkError: Bool {
        if case .networkError = self { return true }
        return false
    }

    /// Errors that should be retried with countdown on the same provider.
    /// Includes both network errors and transient server-side errors (5xx).
    var isRetryable: Bool {
        switch self {
        case .networkError, .transientError:
            return true
        case .invalidAPIKey, .providerError, .decodingError, .rateLimited, .cancelled, .unknown:
            return false
        }
    }

    /// Errors that indicate the provider itself cannot serve this request
    /// (rate limit, invalid key, permanent provider-side rejection). These trigger
    /// an immediate fallback to the next model in a group, without retry countdown.
    ///
    /// Note: transientError and networkError are also fallbackable — after
    /// auto-retry is exhausted on the current model, group fallback kicks in.
    var fallbackReason: String {
        switch self {
        case .rateLimited: return "请求频繁，已限流"
        case .invalidAPIKey: return "API 密钥无效"
        case .providerError(let msg): return "服务商错误：\(String(msg.prefix(60)))"
        case .transientError(let msg): return "服务暂时不可用：\(String(msg.prefix(60)))"
        case .networkError: return "网络错误"
        case .decodingError: return "响应解析失败"
        case .cancelled: return "请求已取消"
        case .unknown: return "未知错误"
        }
    }

    var isFallbackable: Bool {
        switch self {
        case .rateLimited, .invalidAPIKey, .providerError:
            return true
        case .transientError, .networkError, .decodingError, .cancelled, .unknown:
            return false
        }
    }
}
