import Foundation

/// Minimal Anthropic Messages API client.
///
/// There is no official Anthropic Swift SDK, so this talks raw HTTP to
/// `POST /v1/messages`. The API key lives in the Keychain and is never logged.
///
/// Note: calling the API directly from a client app means the key sits on the
/// device. That's acceptable for a personal, single-user app; a shipping product
/// would proxy through a server so the key never leaves it.
struct AnthropicClient {

    static let defaultModel = "claude-opus-5"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"
    /// Opus 5 can decline a request; server-side fallbacks retry it on another
    /// model inside the same call instead of just stopping.
    private static let fallbackBeta = "server-side-fallback-2026-07-01"

    var session: URLSession = .shared
    var model: String = Self.defaultModel

    enum ClientError: LocalizedError {
        case missingAPIKey
        case refused(String)
        case noToolUse
        case httpStatus(Int, body: String)
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "No Anthropic API key set. Add one in Settings to use PDF extraction."
            case .refused(let why):
                return "The model declined this request. \(why)"
            case .noToolUse:
                return "The model replied without returning structured data. Try again."
            case .httpStatus(let code, let body):
                let snippet = body.count > 300 ? String(body.prefix(300)) + "…" : body
                return "Anthropic API error (HTTP \(code)). \(snippet)"
            case .decoding(let detail):
                return "Could not read the model's response: \(detail)"
            }
        }
    }

    // MARK: - Request shape

    /// One tool definition, used to force structured output.
    struct Tool {
        let name: String
        let description: String
        /// JSON Schema as a JSON-serializable dictionary.
        let inputSchema: [String: Any]
    }

    /// Content blocks we send: a PDF document plus an instruction.
    enum RequestContent {
        case pdf(Data, filename: String?)
        case text(String)
    }

    /// Build the request body. Split out from `send` so tests can assert the
    /// exact JSON we put on the wire.
    static func requestBody(
        model: String,
        maxTokens: Int,
        content: [RequestContent],
        system: String?,
        tool: Tool
    ) -> [String: Any] {
        var blocks: [[String: Any]] = []
        for item in content {
            switch item {
            case .pdf(let data, _):
                // Document block must come before the text that refers to it.
                blocks.append([
                    "type": "document",
                    "source": [
                        "type": "base64",
                        "media_type": "application/pdf",
                        // No line breaks — the API rejects wrapped base64.
                        "data": data.base64EncodedString(),
                    ],
                ])
            case .text(let text):
                blocks.append(["type": "text", "text": text])
            }
        }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            // Opus 5 thinks by default; state it explicitly for clarity.
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": "high"],
            "fallbacks": "default",
            "tools": [[
                "name": tool.name,
                "description": tool.description,
                "input_schema": tool.inputSchema,
                // Guarantees the input validates against the schema exactly.
                "strict": true,
            ]],
            "tool_choice": ["type": "tool", "name": tool.name],
            "messages": [["role": "user", "content": blocks]],
        ]
        if let system, !system.isEmpty {
            body["system"] = system
        }
        return body
    }

    // MARK: - Response shape

    private struct Response: Decodable {
        struct Block: Decodable {
            let type: String
            let name: String?
            let text: String?
            /// Only present on `tool_use` blocks. Kept as raw JSON so callers
            /// decode it into whatever type they asked the model for.
            let input: RawJSON?
        }
        struct StopDetails: Decodable {
            let category: String?
            let explanation: String?
        }
        let content: [Block]
        let stop_reason: String?
        let stop_details: StopDetails?
        let model: String?
    }

    /// Holds an arbitrary JSON value so we can re-encode and strongly type it.
    struct RawJSON: Decodable {
        let data: Data
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(JSONValue.self)
            self.data = try JSONEncoder().encode(value)
        }
    }

    /// Send a request and decode the forced tool call's input as `T`.
    func callTool<T: Decodable>(
        content: [RequestContent],
        system: String?,
        tool: Tool,
        maxTokens: Int = 16_000,
        as type: T.Type
    ) async throws -> T {
        guard let apiKey = CredentialStore.get(.anthropicAPIKey), !apiKey.isEmpty else {
            throw ClientError.missingAPIKey
        }

        let body = Self.requestBody(
            model: model, maxTokens: maxTokens,
            content: content, system: system, tool: tool
        )

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // Extraction over a long PDF can take a while.
        request.timeoutInterval = 300

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.httpStatus(
                http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ClientError.decoding(String(describing: error))
        }

        // A refusal arrives as HTTP 200 — always check before reading content.
        if decoded.stop_reason == "refusal" {
            let why = decoded.stop_details?.explanation
                ?? decoded.stop_details?.category
                ?? "No reason given."
            throw ClientError.refused(why)
        }

        guard let toolInput = decoded.content
            .first(where: { $0.type == "tool_use" && $0.name == tool.name })?
            .input
        else { throw ClientError.noToolUse }

        do {
            return try JSONDecoder().decode(T.self, from: toolInput.data)
        } catch {
            throw ClientError.decoding(String(describing: error))
        }
    }
}

/// A decoded-then-re-encodable JSON value, so we can hand arbitrary tool input
/// to a strongly typed `Decodable` without knowing its shape up front.
enum JSONValue: Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:          try c.encodeNil()
        case .bool(let v):   try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v):  try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}
