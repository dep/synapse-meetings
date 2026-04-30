import Foundation

enum OpenRouterError: LocalizedError {
    case missingAPIKey
    case http(status: Int, body: String)
    case decoding(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OpenRouter API key is not set. Add it in Settings."
        case .http(let status, let body):
            return "OpenRouter API error (\(status)): \(body)"
        case .decoding(let detail):
            return "Could not decode OpenRouter response: \(detail)"
        case .empty:
            return "OpenRouter returned an empty response."
        }
    }
}

/// Free-tier OpenRouter access via the OpenAI-compatible chat completions API.
/// Uses the same prompt content as `AnthropicService` (see `SummarizationPrompts`)
/// — the only difference here is the wire format.
struct OpenRouterService: SummarizationProvider {
    static let defaultModel = "google/gemma-4-31b-it:free"

    /// Curated list of free models that handle EN/ES/PT meeting summaries reasonably.
    /// Order matters: the first entry is the default and the recommended pick.
    static let curatedFreeModels: [String] = [
        "google/gemma-4-31b-it:free",
        "google/gemma-3-27b-it:free",
        "google/gemma-4-26b-a4b-it:free",
        "openai/gpt-oss-120b:free"
    ]

    let apiKey: String
    let model: String
    let session: URLSession

    init(apiKey: String, model: String = OpenRouterService.defaultModel, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    static func makeFromKeychain(model: String? = nil) throws -> OpenRouterService {
        guard let raw = KeychainService.shared.get(.openRouterAPIKey) else {
            throw OpenRouterError.missingAPIKey
        }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw OpenRouterError.missingAPIKey
        }
        return OpenRouterService(apiKey: key, model: model ?? defaultModel)
    }

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
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ]
        ]

        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Optional OpenRouter ranking headers — harmless if the project is private.
        request.setValue("https://github.com/dep/synapse-meetings", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Synapse Meetings", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterError.empty
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OpenRouterError.http(status: http.statusCode, body: body)
        }

        struct ChatMessage: Decodable {
            let content: String?
        }
        struct Choice: Decodable {
            let message: ChatMessage?
        }
        struct ChatCompletionResponse: Decodable {
            let choices: [Choice]
        }

        do {
            let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            let text = decoded.choices
                .compactMap { $0.message?.content }
                .first { !$0.isEmpty } ?? ""
            guard !text.isEmpty else { throw OpenRouterError.empty }
            return text
        } catch let err as OpenRouterError {
            throw err
        } catch {
            throw OpenRouterError.decoding(error.localizedDescription)
        }
    }
}
