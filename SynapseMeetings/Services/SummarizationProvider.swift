import Foundation

/// The set of LLM providers Synapse Meetings can summarize through.
/// The raw value is what gets persisted via `@AppStorage("llmProvider")`.
enum LLMProvider: String, CaseIterable, Identifiable {
    case anthropic
    case openrouter

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openrouter: return "OpenRouter"
        }
    }
}

/// Common surface that the pipeline calls regardless of which provider is selected.
/// Both `AnthropicService` and `OpenRouterService` conform.
protocol SummarizationProvider {
    func summarize(
        transcript: String,
        liveNotes: String,
        attendees: [String],
        speakerLabeled: Bool,
        suggestedTitle: String?,
        systemPromptOverride: String?,
        userPromptTemplateOverride: String?
    ) async throws -> String
}

/// Constructs the right `SummarizationProvider` for the user's currently
/// selected provider, pulling the API key from the keychain. Throws the
/// provider's own `missingAPIKey` error if the key is absent — the pipeline
/// already surfaces this through `recording.lastError`.
enum SummarizationFactory {
    static func make(
        provider: LLMProvider,
        anthropicModel: String,
        openRouterModel: String
    ) throws -> SummarizationProvider {
        switch provider {
        case .anthropic:
            return try AnthropicService.makeFromKeychain(model: anthropicModel)
        case .openrouter:
            return try OpenRouterService.makeFromKeychain(model: openRouterModel)
        }
    }
}
