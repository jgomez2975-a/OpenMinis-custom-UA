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

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey(let detail):
            return detail.isEmpty ? "Invalid API key" : "Invalid API key: \(detail)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .providerError(let message):
            return "Provider error: \(message)"
        case .transientError(let message):
            return "Service temporarily unavailable: \(message)"
        case .decodingError(let error):
            return "Decoding error: \(error.localizedDescription)"
        case .rateLimited:
            return "Rate limited — please try again later"
        case .cancelled:
            return "Request was cancelled"
        case .unknown(let error):
            return "Unknown error: \(error?.localizedDescription ?? "no details")"
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
        case .rateLimited: return "Rate limited"
        case .invalidAPIKey: return "Invalid API key"
        case .providerError(let msg): return "Provider error: \(String(msg.prefix(60)))"
        default: return "Error"
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
