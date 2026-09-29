import Foundation

package struct LocatedTools: Equatable, Sendable {
    package var ytDlp: String?
    package var ffmpeg: String?
    package var brew: String?
    package var ytDlpIsHomebrew: Bool
    package var version: String?

    package static let unknown = LocatedTools(ytDlp: nil, ffmpeg: nil, brew: nil, ytDlpIsHomebrew: false, version: nil)
}

package enum ToolLocator {
    /// `/usr/local/bin` is Intel Homebrew. A Finder-launched app does not inherit the shell PATH,
    /// so that directory is checked after PATH rather than instead of it.
    package static let fallbackDirectories = ["/usr/local/bin"]

    package static func locate() -> LocatedTools {
        let yt = find(named: "yt-dlp")
        let ffmpeg = find(named: "ffmpeg")
        let brew = find(named: "brew")
        let owned = yt.map { isHomebrewBinary(resolvedPath: URL(fileURLWithPath: $0).resolvingSymlinksInPath().path) } ?? false
        return LocatedTools(ytDlp: yt, ffmpeg: ffmpeg, brew: brew, ytDlpIsHomebrew: owned, version: nil)
    }

    package static func find(named name: String, pathEnv: String? = nil, exists: (String) -> Bool = canRun) -> String? {
        let preferred = "/opt/homebrew/bin/\(name)"
        if exists(preferred) { return preferred }
        let env = pathEnv ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in env.split(separator: ":") where !directory.isEmpty {
            let candidate = "\(directory)/\(name)"
            if exists(candidate) { return candidate }
        }
        for directory in fallbackDirectories {
            let candidate = "\(directory)/\(name)"
            if exists(candidate) { return candidate }
        }
        return nil
    }

    package static func canRun(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    package static func isHomebrewBinary(resolvedPath: String) -> Bool {
        resolvedPath.contains("/Cellar/")
    }

    package static func childPATH(existing: String) -> String {
        var parts = ["/opt/homebrew/bin", "/usr/local/bin"]
        parts.append(contentsOf: existing.split(separator: ":").map(String.init))
        parts.append(contentsOf: ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        var seen = Set<String>()
        return parts.filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    /// C locale so percents use a dot and progress fields stay stable.
    package static func ytDlpEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = childPATH(existing: env["PATH"] ?? "")
        env["LC_ALL"] = "C"
        env["LANG"] = "C"
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    package static func brewEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = childPATH(existing: env["PATH"] ?? "")
        env["NONINTERACTIVE"] = "1"
        env["HOMEBREW_NO_ANALYTICS"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        return env
    }

    package static func ffmpegDirectory(from ffmpegPath: String?) -> String? {
        guard let ffmpegPath, !ffmpegPath.isEmpty else { return nil }
        return (ffmpegPath as NSString).deletingLastPathComponent
    }

    package static func version(of binary: String, timeout: TimeInterval = 3) -> String? {
        let buffer = LineBuffer()
        guard let process = try? SpawnedProcess.launch(
            executable: binary,
            arguments: ["--version"],
            environment: ytDlpEnvironment(),
            directory: NSTemporaryDirectory(),
            onLine: { buffer.append($0) }
        ) else { return nil }
        let done = DispatchSemaphore(value: 0)
        let exit = ExitBox()
        Thread {
            exit.code = process.waitForExit()
            done.signal()
        }.start()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.killNow()
            done.wait()
            return nil
        }
        guard exit.code == 0 else { return nil }
        let line = buffer.drain().last { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard var text = line?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let prefix = "yt-dlp "
        if text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        return text
    }

    package static func run(_ arguments: [String], environment: [String: String], timeout: TimeInterval? = nil) -> (code: Int32, output: String) {
        guard let executable = arguments.first else {
            return (1, "Missing command.")
        }
        let buffer = LineBuffer()
        guard let process = try? SpawnedProcess.launch(
            executable: executable,
            arguments: Array(arguments.dropFirst()),
            environment: environment,
            directory: NSTemporaryDirectory(),
            onLine: { buffer.append($0) }
        ) else {
            return (1, "Could not start \(executable).")
        }
        let done = DispatchSemaphore(value: 0)
        let exit = ExitBox()
        Thread {
            exit.code = process.waitForExit()
            done.signal()
        }.start()
        if let timeout, done.wait(timeout: .now() + timeout) == .timedOut {
            process.killNow()
            done.wait()
            return (1, "Timed out.")
        } else if timeout == nil {
            done.wait()
        }
        let output = buffer.drain().joined(separator: "\n")
        return (exit.code, output)
    }
}

private final class ExitBox: @unchecked Sendable {
    var code: Int32 = 1
}

package enum PathDisplay {
    package static func abbreviate(_ path: String, home: String) -> String {
        if path == home { return "~" }
        let prefix = home.hasSuffix("/") ? home : home + "/"
        if path.hasPrefix(prefix) {
            return "~/" + path.dropFirst(prefix.count)
        }
        return path
    }
}
