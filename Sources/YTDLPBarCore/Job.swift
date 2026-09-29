import Foundation

package enum DownloadMode: String, Codable, CaseIterable, Equatable, Sendable {
    case video
    case audio

    package var label: String {
        switch self {
        case .video: "Video"
        case .audio: "Audio"
        }
    }
}

package enum VideoQuality: String, Codable, CaseIterable, Equatable, Sendable {
    case best
    case p1080 = "1080"
    case p720 = "720"
    case p480 = "480"

    package var label: String {
        switch self {
        case .best: "Best"
        case .p1080: "1080p"
        case .p720: "720p"
        case .p480: "480p"
        }
    }
}

package enum AudioFormat: String, Codable, CaseIterable, Equatable, Sendable {
    case keep
    case mp3
    case m4a
    case opus
    case flac
    case wav

    package var label: String {
        switch self {
        case .keep: "Keep"
        default: rawValue
        }
    }
}

package enum JobStatus: String, Codable, Equatable, Sendable {
    case queued
    case running
    case done
    case failed
    case cancelled

    package var isFinished: Bool {
        switch self {
        case .done, .failed, .cancelled: true
        case .queued, .running: false
        }
    }
}

package struct DownloadJob: Identifiable, Codable, Equatable, Sendable {
    package var id: UUID
    package var sequence: Int
    package var url: String
    package var mode: DownloadMode
    package var quality: VideoQuality
    package var audioFormat: AudioFormat
    package var destination: String
    package var status: JobStatus
    package var title: String
    package var error: String
    package var filePath: String?
    package var percent: Double?
    package var speed: String
    package var eta: String
    package var added: Date
    package var finished: Date?
    package var pid: Int32?
    package var pidStarted: UInt64?

    package var choiceLabel: String {
        switch mode {
        case .video: "Video · \(quality.label)"
        case .audio: "Audio · \(audioFormat.label)"
        }
    }

    package var displayTitle: String {
        title.isEmpty ? url : title
    }
}

package struct InterruptedProcess: Equatable, Sendable {
    package var pid: Int32
    package var started: UInt64
}
