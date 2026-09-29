import Foundation

package enum ToolStatus {
    package static func message(for tools: LocatedTools) -> String? {
        if tools.ytDlp == nil && tools.brew == nil {
            return "yt-dlp is not installed, and Homebrew was not found to install it."
        }
        if tools.ytDlp == nil {
            return "yt-dlp is not installed, so a download cannot start."
        }
        if tools.ffmpeg == nil && tools.brew == nil {
            return "ffmpeg is not installed, and Homebrew was not found. Video merges and audio conversion need ffmpeg."
        }
        if tools.ffmpeg == nil {
            return "ffmpeg is not installed. Video merges and audio conversion need it."
        }
        return nil
    }

    package static func showsInstall(_ tools: LocatedTools) -> Bool {
        tools.brew != nil && (tools.ytDlp == nil || tools.ffmpeg == nil)
    }

    package static func installArguments(_ tools: LocatedTools) -> [String]? {
        guard let brew = tools.brew else { return nil }
        return [brew, "install", "yt-dlp", "ffmpeg"]
    }

    /// Homebrew-owned binaries update through brew. Anything else uses yt-dlp's own updater.
    package static func updateArguments(_ tools: LocatedTools) -> [String]? {
        guard let ytDlp = tools.ytDlp else { return nil }
        if tools.ytDlpIsHomebrew, let brew = tools.brew {
            return [brew, "upgrade", "yt-dlp"]
        }
        return [ytDlp, "-U"]
    }

    package static func footer(tools: LocatedTools, ready: Bool, notice: String?) -> String {
        if let notice, !notice.isEmpty { return notice }
        if !ready { return "Checking yt-dlp…" }
        if let message = message(for: tools) { return message }
        if let version = tools.version, !version.isEmpty { return "yt-dlp \(version)" }
        return "yt-dlp"
    }

    package static func shortFailure(_ prefix: String, output: String) -> String {
        let cleaned = output.replacingOccurrences(
            of: #"\u{001B}\[[0-9;]*[A-Za-z]"#,
            with: "",
            options: .regularExpression
        )
        let line = cleaned
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty } ?? ""
        if line.isEmpty { return "\(prefix)." }
        let tail = line.count > 180 ? String(line.suffix(180)) : line
        return "\(prefix). \(tail)"
    }
}
