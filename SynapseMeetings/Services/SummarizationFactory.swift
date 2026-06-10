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

/// Everything the summarizer factory needs to build the right provider.
/// Bundled into one value so `AppState`'s `makeSummarizer` test seam stays a
/// single-argument closure (see `Summarizing` in AnthropicService.swift).
struct SummarizerConfig {
    var provider: LLMProvider
    var anthropicModel: String
    var openRouterModel: String
}

/// Constructs the right `Summarizing` implementation for the user's currently
/// selected provider, pulling the API key from the keychain. Throws the
/// provider's own `missingAPIKey` error if the key is absent — the pipeline
/// already surfaces this through `recording.lastError`.
enum SummarizationFactory {
    static func make(_ config: SummarizerConfig) throws -> any Summarizing {
        switch config.provider {
        case .anthropic:
            return try AnthropicService.makeFromKeychain(model: config.anthropicModel)
        case .openrouter:
            return try OpenRouterService.makeFromKeychain(model: config.openRouterModel)
        }
    }
}
