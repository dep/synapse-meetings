import Foundation

enum RecordingStatus: String, Codable {
    case recording
    case transcribing
    case summarizing
    case ready
    case committed
    case failed

    var displayLabel: String {
        switch self {
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        case .summarizing: return "Summarizing…"
        case .ready: return "Ready"
        case .committed: return "Committed"
        case .failed: return "Failed"
        }
    }
}

struct Recording: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var title: String
    var createdAt: Date
    var duration: TimeInterval
    var audioFilename: String
    var transcript: String
    var liveNotes: String
    var summaryMarkdown: String
    var status: RecordingStatus
    var lastError: String?

    var committedRepo: String?
    var committedBranch: String?
    var committedPath: String?
    var committedSha: String?
    var committedAt: Date?

    init(
        id: UUID = UUID(),
        title: String = "Untitled Recording",
        createdAt: Date = Date(),
        duration: TimeInterval = 0,
        audioFilename: String,
        transcript: String = "",
        liveNotes: String = "",
        summaryMarkdown: String = "",
        status: RecordingStatus = .recording,
        lastError: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.audioFilename = audioFilename
        self.transcript = transcript
        self.liveNotes = liveNotes
        self.summaryMarkdown = summaryMarkdown
        self.status = status
        self.lastError = lastError
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        audioFilename = try c.decode(String.self, forKey: .audioFilename)
        transcript = try c.decode(String.self, forKey: .transcript)
        liveNotes = try c.decodeIfPresent(String.self, forKey: .liveNotes) ?? ""
        summaryMarkdown = try c.decode(String.self, forKey: .summaryMarkdown)
        status = try c.decode(RecordingStatus.self, forKey: .status)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        committedRepo = try c.decodeIfPresent(String.self, forKey: .committedRepo)
        committedBranch = try c.decodeIfPresent(String.self, forKey: .committedBranch)
        committedPath = try c.decodeIfPresent(String.self, forKey: .committedPath)
        committedSha = try c.decodeIfPresent(String.self, forKey: .committedSha)
        committedAt = try c.decodeIfPresent(Date.self, forKey: .committedAt)
    }
}
