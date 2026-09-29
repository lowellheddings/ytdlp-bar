import Foundation

package enum ArgumentError: Error, Equatable {
    case badURL
    case badDestination
}

package enum YTDLPArguments {
    /// Arguments for one job. Values are passed as an array, never through a shell.
    package static func make(job: DownloadJob, ffmpegDirectory: String?) throws -> [String] {
        try validate(job)
        var args: [String] = [
            "--newline",
            "--no-colors",
            "--ignore-config",
            // A playlist URL would otherwise fan out into downloads the queue does not track.
            "--no-playlist",
            "--paths", job.destination,
            "--output", "%(title)s [%(id)s].%(ext)s",
            "--progress-template",
            "download:\(Marks.progress)%(progress._percent_str)s\t%(progress._speed_str)s\t%(progress._eta_str)s\t%(info.title)s",
            "--print", "before_dl:\(Marks.title)%(title)s",
            // after_move is the final path. after_video reports NA, and post_process
            // still names the source file when audio is extracted.
            "--print", "after_move:\(Marks.file)%(filepath)s",
            // --print turns on quiet and simulate. Put these after it so the file is actually saved
            // and progress lines still arrive.
            "--no-simulate",
            "--progress",
        ]
        if let ffmpegDirectory, !ffmpegDirectory.isEmpty {
            args += ["--ffmpeg-location", ffmpegDirectory]
        }
        args += formatArguments(mode: job.mode, quality: job.quality, audioFormat: job.audioFormat)
        args.append("--")
        args.append(job.url)
        return args
    }

    package static func formatArguments(mode: DownloadMode, quality: VideoQuality, audioFormat: AudioFormat) -> [String] {
        if mode == .audio {
            // No --audio-format on Keep. yt-dlp then copies the audio stream instead of re-encoding it.
            var args = ["--format", "ba/b", "--extract-audio"]
            if audioFormat != .keep {
                args += ["--audio-format", audioFormat.rawValue]
            }
            return args
        }
        if quality == .best {
            return ["--format", "bv*+ba/b"]
        }
        let height = quality.rawValue
        return ["--format", "bv*[height<=\(height)]+ba/b[height<=\(height)]/b"]
    }

    package static func validate(_ job: DownloadJob) throws {
        guard LinkCheck.normalize(job.url) != nil else { throw ArgumentError.badURL }
        guard job.destination.hasPrefix("/"),
              !job.destination.contains("\n"),
              !job.destination.contains("\u{0}")
        else { throw ArgumentError.badDestination }
    }
}
