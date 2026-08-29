import Foundation

/// Turns app-server stderr into a small, display-safe diagnostic. The bundled
/// runtime commonly writes structured tracing JSON to stderr; presenting that
/// envelope verbatim makes an ordinary failure look like a developer console.
enum CodexRuntimeNoticeProjection {
    private static let maximumCharacters = 480

    static func detail(from rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let primary = decodedJSON(from: trimmed)
            .flatMap(preferredMessage(from:))
            ?? preferredMessageFromEmbeddedJSON(in: trimmed)
            ?? trimmed
        let extracted = preferredMessageFromEmbeddedJSON(in: primary) ?? primary
        let readable = extracted
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        guard !readable.isEmpty else { return nil }
        return DelegationSafeText.sanitizeDiagnostic(
            readable,
            limit: maximumCharacters
        )
    }

    private static func preferredMessage(from value: JSONValue) -> String? {
        let candidates = [
            value["fields"]?["message"]?.stringValue,
            value["error"]?["message"]?.stringValue,
            value["message"]?.stringValue,
            value["detail"]?.stringValue,
            value["reason"]?.stringValue,
        ]
        return candidates.lazy.compactMap(nonBlank).first
    }

    private static func preferredMessageFromEmbeddedJSON(in value: String) -> String? {
        for index in value.indices where value[index] == "{" {
            guard let decoded = decodedJSON(from: String(value[index...])),
                  let message = preferredMessage(from: decoded) else { continue }
            return message
        }
        return nil
    }

    private static func decodedJSON(from value: String) -> JSONValue? {
        guard let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
