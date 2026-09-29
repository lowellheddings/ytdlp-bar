import Foundation

package enum Marks {
    package static let progress = "__YTDLPBAR_PROGRESS__"
    package static let title = "__YTDLPBAR_TITLE__"
    package static let file = "__YTDLPBAR_FILE__"
}

package enum YTDLPEvent: Equatable, Sendable {
    case progress(percent: Double?, speed: String, eta: String, title: String?)
    case title(String)
    case file(String, trusted: Bool)
    case log(String)
}

package enum LineParser {
    package static func parse(_ raw: String) -> YTDLPEvent {
        var line = stripANSI(raw)
        if line.hasSuffix("\r") { line.removeLast() }
        if line.isEmpty { return .log("") }

        if let rest = payload(line, mark: Marks.progress) {
            return parseProgress(rest)
        }
        if let rest = payload(line, mark: Marks.title) {
            return .title(rest.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let rest = payload(line, mark: Marks.file) {
            let path = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            // yt-dlp prints NA when that field is not filled in yet.
            if path.isEmpty || path.compare("NA", options: .caseInsensitive) == .orderedSame
                || path.compare("N/A", options: .caseInsensitive) == .orderedSame {
                return .log(line)
            }
            return .file(path, trusted: true)
        }
        if line.contains("[Merger]"), let path = lastQuoted(line) {
            return .file(path, trusted: true)
        }
        if line.contains("[MoveFiles]"), let path = lastQuoted(line) {
            return .file(path, trusted: true)
        }
        if line.contains("[ExtractAudio]"), let path = destinationPath(line) {
            return .file(path, trusted: true)
        }
        if line.contains("[download]"), line.contains("Destination:"), let path = destinationPath(line) {
            return .file(path, trusted: false)
        }
        return .log(line)
    }

    package static func parsePercent(_ raw: String) -> Double? {
        let cleaned = raw.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty || cleaned.compare("NA", options: .caseInsensitive) == .orderedSame { return nil }
        if cleaned.compare("N/A", options: .caseInsensitive) == .orderedSame { return nil }
        guard let value = Double(cleaned), value.isFinite else { return nil }
        return min(100, max(0, value))
    }

    private static func payload(_ line: String, mark: String) -> String? {
        var body = line
        let prefix = "download:"
        if body.hasPrefix(prefix) {
            body.removeFirst(prefix.count)
        }
        guard body.hasPrefix(mark) else { return nil }
        return String(body.dropFirst(mark.count))
    }

    private static func parseProgress(_ rest: String) -> YTDLPEvent {
        let parts = rest.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        let percent = parts.count > 0 ? parsePercent(parts[0]) : nil
        let speed = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        let eta = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : ""
        let title = parts.count > 3 ? cleanTitle(parts[3]) : nil
        return .progress(percent: percent, speed: speed, eta: eta, title: title)
    }

    private static func cleanTitle(_ raw: String) -> String? {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || title == "NA" { return nil }
        return title
    }

    private static func lastQuoted(_ line: String) -> String? {
        guard let end = line.lastIndex(of: "\"") else { return nil }
        let head = line[..<end]
        guard let start = head.lastIndex(of: "\"") else { return nil }
        let path = head[head.index(after: start)..<end]
        if path.isEmpty { return nil }
        return String(path)
    }

    private static func destinationPath(_ line: String) -> String? {
        guard let range = line.range(of: "Destination:") else { return nil }
        var path = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 {
            path.removeFirst()
            path.removeLast()
        }
        return path.isEmpty ? nil : path
    }

    private static func stripANSI(_ raw: String) -> String {
        raw.replacingOccurrences(
            of: #"\u{001B}\[[0-9;]*[A-Za-z]"#,
            with: "",
            options: .regularExpression
        )
    }
}

package enum ErrorText {
    package static func best(from log: [String], code: Int32) -> String {
        if let line = log.reversed().first(where: { $0.contains("ERROR:") }) {
            var text = line
            if let range = text.range(of: "ERROR:") {
                text = String(text[range.upperBound...])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count > 240 {
                text = String(text.prefix(240))
            }
            if !text.isEmpty { return text }
        }
        return "yt-dlp stopped (exit \(code))."
    }
}
