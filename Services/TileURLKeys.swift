//
//  TileURLKeys.swift
//  QuiteListie
//
//  Key hygiene for user-supplied tile URLs. API keys travel in the query
//  string by design (they're client-side identifiers, not secrets we can
//  protect — provider-side quotas are the real control), but they must not
//  leak into two places:
//
//   * cache-namespace hashes — or every key rotation orphans the whole cache;
//   * displayed strings — settings rows and error messages get shoulder-surfed
//     and screenshotted.
//

import Foundation

enum TileURLKeys {
    /// Query-parameter names that carry keys/auth tokens across common tile
    /// providers. Matched case-insensitively.
    static let authParamNames: Set<String> = [
        "key", "apikey", "api_key", "api-key",
        "token", "access_token", "accesstoken", "auth", "authkey",
        "signature", "sig", "app_id", "app_code", "subscription-key",
    ]

    static func isAuthParam(_ name: String) -> Bool {
        authParamNames.contains(name.lowercased())
    }

    /// The template with recognised key/auth query params removed — the stable
    /// identity used for cache-namespace hashing, so rotating a key doesn't
    /// orphan the layer's cached tiles. Non-auth params (format, style…) stay:
    /// they genuinely change what bytes a tile request returns.
    ///
    /// Plain string surgery, not URLComponents: templates contain `{z}`-style
    /// braces that URLComponents refuses to parse.
    static func strippingAuthParams(fromTemplate template: String) -> String {
        guard let qIdx = template.firstIndex(of: "?") else { return template }
        let base = template[..<qIdx]
        let kept = template[template.index(after: qIdx)...]
            .split(separator: "&")
            .filter { pair in
                let name = pair.split(separator: "=", maxSplits: 1).first ?? pair
                return !isAuthParam(String(name))
            }
        return kept.isEmpty ? String(base) : base + "?" + kept.joined(separator: "&")
    }

    /// Replace the *values* of recognised key/auth params with a bullet run,
    /// for display only (settings captions, scan errors). Works on any string
    /// that may embed a URL, not just well-formed templates.
    static func redactingAuthParams(in text: String) -> String {
        redactionRegex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text),
            withTemplate: "$1•••")
    }

    private static let redactionRegex: NSRegularExpression = {
        // (?<=[?&]) so `format=` never matches inside `key=…&format=…` values,
        // and param names elsewhere in prose stay untouched.
        let names = authParamNames
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        return try! NSRegularExpression(
            pattern: "(?i)(?<=[?&])((?:\(names))=)[^&\\s\"'<>]+")
    }()
}

// MARK: - Layer health

/// Session-wide sink for terminal tile-layer failures (rejected key, persistent
/// rate-limiting). Reports at most once per source per session — a flaky server
/// must not turn the map into a banner farm.
enum TileLayerHealth {
    /// Posted (from any thread) when a layer hits a terminal auth failure.
    /// userInfo: `sourceIDKey` (String), `messageKey` (String), `statusKey` (Int).
    static let authFailureNotification = Notification.Name("tileLayerAuthFailure")
    static let sourceIDKey = "sourceID"
    static let messageKey = "message"
    static let statusKey = "status"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var notifiedSourceIDs: Set<String> = []

    /// Report a terminal failure for a source. Returns true if this was the
    /// first report for the source this session (and a notification was posted).
    @discardableResult
    static func reportAuthFailure(sourceID: String, name: String, status: Int) -> Bool {
        lock.lock()
        let first = notifiedSourceIDs.insert(sourceID).inserted
        lock.unlock()
        guard first else { return false }
        NotificationCenter.default.post(
            name: authFailureNotification, object: nil,
            userInfo: [sourceIDKey: sourceID,
                       messageKey: message(name: name, status: status),
                       statusKey: status])
        return true
    }

    static func message(name: String, status: Int) -> String {
        status == 429
            ? "Layer “\(name)” keeps hitting its server’s rate limit — check Custom Map Layers."
            : "Layer “\(name)” rejected your API key — check Custom Map Layers."
    }

    /// Allow a fresh report after the user plausibly fixed the key (e.g. edited
    /// the layer), and give tests a clean slate.
    static func reset(sourceID: String? = nil) {
        lock.lock()
        if let sourceID {
            notifiedSourceIDs.remove(sourceID)
        } else {
            notifiedSourceIDs.removeAll()
        }
        lock.unlock()
    }
}
