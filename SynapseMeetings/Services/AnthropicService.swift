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

struct AnthropicService {
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
        suggestedTitle: String?
    ) async throws -> String {
        let systemPrompt = Self.systemPrompt
        let userPrompt = Self.userPrompt(
            transcript: transcript,
            liveNotes: liveNotes,
            attendees: attendees,
            suggestedTitle: suggestedTitle
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

    private static let systemPrompt = """
    You are a meticulous note-taker that turns raw meeting transcripts into clean, scannable Markdown summaries.
    Always respond with ONLY the Markdown summary — no preamble, no code fences around the whole document.
    Follow the structure exactly. If a section has no content, write `_None_` under it rather than omitting the section.

    The first line MUST be a single H1 heading (`# Title Here`) with a SHORT (3–8 words), specific, descriptive title that captures what the meeting was actually about. Examples of good titles: `# Q3 Roadmap Sync`, `# Hiring Loop Debrief — Sarah`, `# Auth Migration Kickoff`. Do NOT use generic titles like `# Recording`, `# Meeting Notes`, `# Audio Test`, or anything containing a date — the date is already tracked separately. If the transcript is too short or contains no meaningful content (e.g. just a mic test), use `# Brief Audio Note`.
    """

    private static func userPrompt(
        transcript: String,
        liveNotes: String,
        attendees: [String],
        suggestedTitle: String?
    ) -> String {
        let notesBlock: String
        let trimmedNotes = liveNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedNotes.isEmpty {
            notesBlock = ""
        } else {
            notesBlock = """

            The user took the following notes DURING the meeting. Treat these as high-signal — the user thought they were important enough to write down in real-time. Make sure the summary reflects them, especially in Key Points and Action Items:

            \"\"\"
            \(trimmedNotes)
            \"\"\"

            """
        }
        let attendeesBlock: String
        if attendees.isEmpty {
            attendeesBlock = ""
        } else {
            let bulletList = attendees.map { "- [[\($0)]]" }.joined(separator: "\n")
            attendeesBlock = """

            The user manually specified the meeting attendees below. This list is AUTHORITATIVE — use it verbatim for the `## 👥 Participants` section, in the exact order given. Do NOT add inferred names from the transcript, do NOT remove anyone, and do NOT change spelling.

            Additionally, throughout the ENTIRE summary (Participants, Key Points, Action Items, Open Questions, Next Steps, Quotes, and the opening paragraph), wrap every occurrence of these names in double square brackets like `[[Name]]` so they link in an Obsidian-style vault. Match names case-insensitively and bracket each occurrence, including possessives (e.g. `[[Sarah]]'s`). Only bracket names from this list — do not bracket other people mentioned in the transcript.

            Attendees:
            \(bulletList)

            """
        }
        return """
        Generate a Markdown meeting summary from the transcript below using EXACTLY this structure:

        # <title>

        <one-paragraph summary of the recording>

        ## 👥 Participants

        - <participant 1>
        - <participant 2>

        ## 🎯 Key Points

        - Topic 1: brief description and key points
        - Topic 2: brief description and key points

        ## ✅ Action Items

        - Action item 1
        - Action item 2

        ## ❓ Open Questions

        - Question 1
        - Question 2

        ## ⏭️ Next Steps

        Summarize what happens next and any upcoming meetings or deadlines mentioned.

        ## 💭 Quotes

        Include any particularly important or memorable statements that capture the essence of discussions. Omit this section if nothing notable.

        ---
        \(attendeesBlock)\(notesBlock)
        Transcript:
        \"\"\"
        \(transcript)
        \"\"\"
        """
    }
}
