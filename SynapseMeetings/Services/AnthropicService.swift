import Foundation

enum AnthropicError: LocalizedError {
    case missingAPIKey
    case http(status: Int, body: String)
    case decoding(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Anthropic API key is not set. Add it in Settings."
        case .http(let status, let body):
            return "Anthropic API error (\(status)): \(body)"
        case .decoding(let detail):
            return "Could not decode Anthropic response: \(detail)"
        case .empty:
            return "Anthropic returned an empty response."
        }
    }
}

struct AnthropicService: SummarizationProvider {
    static let defaultModel = "claude-sonnet-4-6"

    let apiKey: String
    let model: String
    let session: URLSession

    init(apiKey: String, model: String = AnthropicService.defaultModel, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    static func makeFromKeychain(model: String? = nil) throws -> AnthropicService {
        guard let raw = KeychainService.shared.get(.anthropicAPIKey) else {
            throw AnthropicError.missingAPIKey
        }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw AnthropicError.missingAPIKey
        }
        return AnthropicService(apiKey: key, model: model ?? defaultModel)
    }

    /// Returns markdown matching the Synapse Meetings summary template.
    func summarize(
        transcript: String,
        liveNotes: String = "",
        attendees: [String] = [],
        speakerLabeled: Bool = false,
        suggestedTitle: String?,
        systemPromptOverride: String? = nil,
        userPromptTemplateOverride: String? = nil
    ) async throws -> String {
        let systemPrompt = (systemPromptOverride?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? SummarizationPrompts.defaultSystemPrompt
        let template = (userPromptTemplateOverride?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? SummarizationPrompts.defaultUserPromptTemplate
        let userPrompt = SummarizationPrompts.renderUserPrompt(
            template: template,
            transcript: transcript,
            liveNotes: liveNotes,
            attendees: attendees,
            speakerLabeled: speakerLabeled
        )

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userPrompt]
            ]
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AnthropicError.empty
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AnthropicError.http(status: http.statusCode, body: body)
        }

        struct ContentBlock: Decodable {
            let type: String
            let text: String?
        }
        struct AnthropicResponse: Decodable {
            let content: [ContentBlock]
        }

        do {
            let decoded = try JSONDecoder().decode(AnthropicResponse.self, from: data)
            let text = decoded.content
                .compactMap { $0.type == "text" ? $0.text : nil }
                .joined(separator: "\n")
            guard !text.isEmpty else { throw AnthropicError.empty }
            return text
        } catch let err as AnthropicError {
            throw err
        } catch {
            throw AnthropicError.decoding(error.localizedDescription)
        }
    }

    // Backwards-compat shims that delegate to the shared `SummarizationPrompts`
    // namespace. Existing callers (SettingsView, AnthropicPromptTests) reference
    // these via `AnthropicService.defaultSystemPrompt` etc. — keep them working.
    static var defaultSystemPrompt: String { SummarizationPrompts.defaultSystemPrompt }
    static var defaultUserPromptTemplate: String { SummarizationPrompts.defaultUserPromptTemplate }

    static func testRenderUserPrompt(
        template: String,
        transcript: String,
        liveNotes: String,
        attendees: [String],
        speakerLabeled: Bool
    ) -> String {
        SummarizationPrompts.renderUserPrompt(
            template: template,
            transcript: transcript,
            liveNotes: liveNotes,
            attendees: attendees,
            speakerLabeled: speakerLabeled
        )
    }
}
