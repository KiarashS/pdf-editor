import Foundation

/// Settings for talking to the Claude Messages API.
public struct ClaudeConfiguration: Equatable {
    public var apiKey: String
    public var model: String
    /// `low`, `medium`, `high`, `xhigh` or `max`.
    public var effort: String
    public var maxTokens: Int
    public var baseURL: URL

    public static let defaultModel = "claude-opus-5-5"
    public static let availableModels = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"]
    public static let effortLevels = ["low", "medium", "high", "xhigh", "max"]

    public init(apiKey: String,
                model: String = ClaudeConfiguration.defaultModel,
                effort: String = "medium",
                maxTokens: Int = 64_000,
                baseURL: URL = URL(string: "https://api.anthropic.com")!) {
        self.apiKey = apiKey
        self.model = model
        self.effort = effort
        self.maxTokens = maxTokens
        self.baseURL = baseURL
    }
}

/// One content block of a user or assistant turn.
public enum ClaudeContentBlock: Equatable {
    case text(String)
    /// A PDF sent as a base64 document block.
    case pdf(Data, title: String?, cache: Bool)
    /// Plain text sent as a document block (used when the PDF is too large).
    case textDocument(String, title: String?, cache: Bool)

    var json: [String: Any] {
        switch self {
        case .text(let text):
            return ["type": "text", "text": text]
        case .pdf(let data, let title, let cache):
            var block: [String: Any] = [
                "type": "document",
                "source": ["type": "base64", "media_type": "application/pdf", "data": data.base64EncodedString()],
            ]
            if let title { block["title"] = title }
            if cache { block["cache_control"] = ["type": "ephemeral"] }
            return block
        case .textDocument(let text, let title, let cache):
            var block: [String: Any] = [
                "type": "document",
                "source": ["type": "text", "media_type": "text/plain", "data": text],
            ]
            if let title { block["title"] = title }
            if cache { block["cache_control"] = ["type": "ephemeral"] }
            return block
        }
    }
}

public struct ClaudeMessage: Equatable {
    public enum Role: String { case user, assistant }
    public var role: Role
    public var content: [ClaudeContentBlock]

    public init(role: Role, content: [ClaudeContentBlock]) {
        self.role = role
        self.content = content
    }

    public static func user(_ text: String) -> ClaudeMessage { ClaudeMessage(role: .user, content: [.text(text)]) }
    public static func assistant(_ text: String) -> ClaudeMessage { ClaudeMessage(role: .assistant, content: [.text(text)]) }
}

/// Events surfaced while streaming a response.
public enum ClaudeStreamEvent: Equatable, Sendable {
    case textDelta(String)
    case stopped(reason: String?)
}

public enum ClaudeError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case http(status: Int, message: String)
    case api(type: String, message: String)
    case refused(String?)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your Anthropic API key in Settings to use the AI assistant."
        case .http(let status, let message):
            return "The Claude API returned HTTP \(status): \(message)"
        case .api(let type, let message):
            return "Claude API error (\(type)): \(message)"
        case .refused(let explanation):
            return "Claude declined this request." + (explanation.map { " \($0)" } ?? "")
        case .invalidResponse:
            return "The Claude API returned a response that could not be read."
        }
    }
}

/// Parses `data:` lines of the Messages API server-sent event stream.
public struct ClaudeSSEParser {
    public init() {}

    /// Returns the event carried by one line of the stream, if any.
    /// Throws for `error` events and refusals.
    public func parse(line: String) throws -> ClaudeStreamEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty,
              let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }

        switch type {
        case "content_block_delta":
            guard let delta = object["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return nil }
            return .textDelta(text)
        case "message_delta":
            let delta = object["delta"] as? [String: Any]
            let reason = delta?["stop_reason"] as? String
            if reason == "refusal" {
                let details = delta?["stop_details"] as? [String: Any]
                throw ClaudeError.refused(details?["explanation"] as? String)
            }
            return .stopped(reason: reason)
        case "error":
            let error = object["error"] as? [String: Any]
            throw ClaudeError.api(type: error?["type"] as? String ?? "error",
                                  message: error?["message"] as? String ?? "Unknown error")
        default:
            return nil
        }
    }
}

/// A small client for the Claude Messages API using URLSession and streaming.
///
/// Swift has no official Anthropic SDK, so requests are sent as raw HTTP.
public final class ClaudeClient {
    public let configuration: ClaudeConfiguration
    private let session: URLSession

    public init(configuration: ClaudeConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func makeRequest(system: String?, messages: [ClaudeMessage]) throws -> URLRequest {
        guard !configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClaudeError.missingAPIKey
        }
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // Server-side refusal fallback: a declined request is retried on the
        // recommended fallback model inside the same call.
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")

        var body: [String: Any] = [
            "model": configuration.model,
            "max_tokens": configuration.maxTokens,
            "stream": true,
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": configuration.effort],
            "fallbacks": "default",
            "messages": messages.map { message in
                ["role": message.role.rawValue, "content": message.content.map(\.json)] as [String: Any]
            },
        ]
        if let system, !system.isEmpty { body["system"] = system }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Streams the assistant's reply as text deltas.
    public func stream(system: String?, messages: [ClaudeMessage]) -> AsyncThrowingStream<ClaudeStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(system: system, messages: messages)
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw ClaudeError.invalidResponse }
                    guard (200..<300).contains(http.statusCode) else {
                        var raw = Data()
                        for try await byte in bytes { raw.append(byte) }
                        throw ClaudeClient.httpError(status: http.statusCode, body: raw)
                    }
                    let parser = ClaudeSSEParser()
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if let event = try parser.parse(line: line) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Convenience that collects the full streamed reply.
    public func complete(system: String?, messages: [ClaudeMessage]) async throws -> String {
        var text = ""
        for try await event in stream(system: system, messages: messages) {
            if case .textDelta(let delta) = event { text += delta }
        }
        return text
    }

    static func httpError(status: Int, body: Data) -> ClaudeError {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return .http(status: status, message: message)
        }
        return .http(status: status, message: String(data: body, encoding: .utf8) ?? "No details")
    }
}
