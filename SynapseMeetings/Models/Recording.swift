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
        self.summaryMarkdown = summaryMarkdown
        self.status = status
        self.lastError = lastError
    }
}
