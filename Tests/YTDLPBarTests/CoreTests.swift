import Darwin
import XCTest
@testable import YTDLPBarCore

final class CoreTests: XCTestCase {
    func testLinkCheckAcceptsHTTP() {
        XCTAssertEqual(LinkCheck.normalize("  https://youtu.be/abc  "), "https://youtu.be/abc")
        XCTAssertEqual(LinkCheck.normalize("http://example.com/a?b=1"), "http://example.com/a?b=1")
    }

    func testLinkCheckRejectsNoise() {
        XCTAssertNil(LinkCheck.normalize(""))
        XCTAssertNil(LinkCheck.normalize("not a url"))
        XCTAssertNil(LinkCheck.normalize("ftp://example.com/a"))
        XCTAssertNil(LinkCheck.normalize("https://example.com/a\nhttps://other.example/b"))
        XCTAssertNil(LinkCheck.normalize("https://example.com/a b"))
        XCTAssertNil(LinkCheck.normalize("https://"))
    }

    func testVideoArgumentsCapHeightAndIgnorePlaylists() throws {
        let job = sampleJob(mode: .video, quality: .p1080, audioFormat: .mp3)
        let args = try YTDLPArguments.make(job: job, ffmpegDirectory: "/opt/homebrew/bin")
        XCTAssertEqual(args[args.count - 2], "--")
        XCTAssertEqual(args.last, job.url)
        XCTAssertTrue(args.contains("--no-playlist"))
        XCTAssertTrue(args.contains("--ignore-config"))
        XCTAssertTrue(args.contains("--no-simulate"))
        XCTAssertTrue(args.contains("--progress"))
        XCTAssertTrue(args.contains("after_move:\(Marks.file)%(filepath)s"))
        XCTAssertFalse(args.contains(where: { $0.contains("after_video:") }))
        let printAt = try XCTUnwrap(args.firstIndex(of: "--print"))
        let simulateAt = try XCTUnwrap(args.firstIndex(of: "--no-simulate"))
        XCTAssertGreaterThan(simulateAt, printAt)
        XCTAssertTrue(args.contains("bv*[height<=1080]+ba/b[height<=1080]/b"))
        XCTAssertTrue(args.contains("/opt/homebrew/bin"))
        XCTAssertTrue(args.contains(job.destination))
        XCTAssertFalse(args.contains("--audio-format"))
    }

    func testBestVideoFormat() {
        XCTAssertEqual(
            YTDLPArguments.formatArguments(mode: .video, quality: .best, audioFormat: .keep),
            ["--format", "bv*+ba/b"]
        )
    }

    func testKeepAudioDoesNotAskForAReencode() {
        let args = YTDLPArguments.formatArguments(mode: .audio, quality: .best, audioFormat: .keep)
        XCTAssertEqual(args, ["--format", "ba/b", "--extract-audio"])
        for forbidden in ["--audio-format", "--audio-quality", "--recode-video", "--remux-video", "--postprocessor-args"] {
            XCTAssertFalse(args.contains(forbidden), forbidden)
        }
    }

    func testConvertedAudioNamesTheContainer() {
        let args = YTDLPArguments.formatArguments(mode: .audio, quality: .p480, audioFormat: .flac)
        XCTAssertEqual(args, ["--format", "ba/b", "--extract-audio", "--audio-format", "flac"])
    }

    func testRejectsADestinationThatCouldSplitArguments() {
        var job = sampleJob(mode: .video, quality: .best, audioFormat: .keep)
        job.destination = "/tmp/bad\n--exec"
        XCTAssertThrowsError(try YTDLPArguments.make(job: job, ffmpegDirectory: nil))
    }

    func testProgressLine() {
        let event = LineParser.parse("__YTDLPBAR_PROGRESS__  42.3%\t 1.20MiB/s\t00:09\tA Title")
        XCTAssertEqual(event, .progress(percent: 42.3, speed: "1.20MiB/s", eta: "00:09", title: "A Title"))
        let live = LineParser.parse("download:__YTDLPBAR_PROGRESS__  46.4%\t  2.44MiB/s\t00:00\tflower")
        XCTAssertEqual(live, .progress(percent: 46.4, speed: "2.44MiB/s", eta: "00:00", title: "flower"))
    }

    func testProgressKeepsTitleTabsAndDropsNA() {
        let titled = LineParser.parse("__YTDLPBAR_PROGRESS__10%\t1MiB/s\t00:01\tHello\tWorld")
        XCTAssertEqual(titled, .progress(percent: 10, speed: "1MiB/s", eta: "00:01", title: "Hello\tWorld"))
        let missing = LineParser.parse("__YTDLPBAR_PROGRESS__  NA%\tUnknown\tNA\tNA")
        XCTAssertEqual(missing, .progress(percent: nil, speed: "Unknown", eta: "NA", title: nil))
    }

    func testFileHints() {
        XCTAssertEqual(
            LineParser.parse("__YTDLPBAR_FILE__/Users/me/Downloads/A [id].mp4"),
            .file("/Users/me/Downloads/A [id].mp4", trusted: true)
        )
        XCTAssertEqual(LineParser.parse("__YTDLPBAR_FILE__NA"), .log("__YTDLPBAR_FILE__NA"))
        XCTAssertEqual(
            LineParser.parse("[Merger] Merging formats into \"/Users/me/Downloads/A [id].mp4\""),
            .file("/Users/me/Downloads/A [id].mp4", trusted: true)
        )
        XCTAssertEqual(
            LineParser.parse("[ExtractAudio] Destination: /Users/me/Downloads/A [id].mp3"),
            .file("/Users/me/Downloads/A [id].mp3", trusted: true)
        )
        XCTAssertEqual(
            LineParser.parse("[download] Destination: /Users/me/Downloads/A [id].f137.mp4"),
            .file("/Users/me/Downloads/A [id].f137.mp4", trusted: false)
        )
        XCTAssertEqual(
            LineParser.parse("[MoveFiles] Moving file \"/tmp/a.f137.mp4\" to \"/tmp/a.mp4\""),
            .file("/tmp/a.mp4", trusted: true)
        )
        XCTAssertEqual(LineParser.parse("__YTDLPBAR_TITLE__Hello"), .title("Hello"))
    }

    func testErrorTextUsesTheLastError() {
        let message = ErrorText.best(from: ["noise", "ERROR: first", "ERROR: Private video"], code: 1)
        XCTAssertEqual(message, "Private video")
        XCTAssertEqual(ErrorText.best(from: ["nope"], code: 2), "yt-dlp stopped (exit 2).")
    }

    func testQueueRunsOneAndKeepsOrder() {
        var queue = DownloadQueue()
        let first = queue.add(url: "https://example.com/a", mode: .video, quality: .best, audioFormat: .keep, destination: "/tmp")
        let second = queue.add(url: "https://example.com/b", mode: .audio, quality: .p720, audioFormat: .mp3, destination: "/tmp/other")
        XCTAssertEqual(queue.nextQueued()?.id, first.id)
        XCTAssertEqual(second.audioFormat, .mp3)
        XCTAssertEqual(second.destination, "/tmp/other")
        queue.markRunning(id: first.id, pid: 10, pidStarted: 1)
        XCTAssertEqual(queue.nextQueued()?.id, second.id)
        XCTAssertFalse(queue.removeQueued(id: first.id))
        XCTAssertTrue(queue.removeQueued(id: second.id))
        XCTAssertNil(queue.nextQueued())
        queue.finish(id: first.id, status: .cancelled, error: "", filePath: nil)
        XCTAssertEqual(queue.job(id: first.id)?.status, .cancelled)
        XCTAssertTrue(queue.hasFinished)
        queue.clearFinished()
        XCTAssertTrue(queue.jobs.isEmpty)
    }

    func testInterruptedJobReturnsToTheQueueWithoutItsOldPid() {
        var queue = DownloadQueue()
        let job = queue.add(url: "https://example.com/a", mode: .video, quality: .p480, audioFormat: .keep, destination: "/tmp")
        queue.markRunning(id: job.id, pid: 44, pidStarted: 9)
        queue.noteProgress(id: job.id, percent: 12, speed: "1MiB/s", eta: "00:01")
        let interrupted = queue.takeInterrupted()
        XCTAssertEqual(interrupted, [InterruptedProcess(pid: 44, started: 9)])
        let restored = queue.job(id: job.id)
        XCTAssertEqual(restored?.status, .queued)
        XCTAssertNil(restored?.pid)
        XCTAssertNil(restored?.percent)
        XCTAssertEqual(queue.nextQueued()?.id, job.id)
    }

    func testJobStoreRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = JobStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        var queue = DownloadQueue()
        let job = queue.add(url: "https://example.com/a", mode: .audio, quality: .best, audioFormat: .opus, destination: "/tmp/out")
        queue.noteTitle(id: job.id, title: "A Title")
        store.saveSync(queue.jobs)
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].title, "A Title")
        XCTAssertEqual(loaded[0].audioFormat, .opus)
        XCTAssertEqual(loaded[0].url, job.url)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.file.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, 0o600)
    }

    func testCorruptJobFileIsMovedAside() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = JobStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not json".utf8).write(to: store.file)
        XCTAssertEqual(store.load(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.file.appendingPathExtension("corrupt").path))
    }

    func testToolMessages() {
        let missing = LocatedTools(ytDlp: nil, ffmpeg: nil, brew: "/opt/homebrew/bin/brew", ytDlpIsHomebrew: false, version: nil)
        XCTAssertEqual(ToolStatus.message(for: missing), "yt-dlp is not installed, so a download cannot start.")
        XCTAssertEqual(ToolStatus.installArguments(missing), ["/opt/homebrew/bin/brew", "install", "yt-dlp", "ffmpeg"])
        XCTAssertNil(ToolStatus.updateArguments(missing))

        let noBrew = LocatedTools(ytDlp: nil, ffmpeg: nil, brew: nil, ytDlpIsHomebrew: false, version: nil)
        XCTAssertEqual(
            ToolStatus.message(for: noBrew),
            "yt-dlp is not installed, and Homebrew was not found to install it."
        )
        XCTAssertFalse(ToolStatus.showsInstall(noBrew))

        let noFFmpeg = LocatedTools(
            ytDlp: "/opt/homebrew/bin/yt-dlp",
            ffmpeg: nil,
            brew: "/opt/homebrew/bin/brew",
            ytDlpIsHomebrew: true,
            version: "2026.1.1"
        )
        XCTAssertEqual(
            ToolStatus.message(for: noFFmpeg),
            "ffmpeg is not installed. Video merges and audio conversion need it."
        )
        XCTAssertTrue(ToolStatus.showsInstall(noFFmpeg))
    }

    func testUpdateCommandFollowsWhoOwnsTheBinary() {
        let brewed = LocatedTools(
            ytDlp: "/opt/homebrew/bin/yt-dlp",
            ffmpeg: "/opt/homebrew/bin/ffmpeg",
            brew: "/opt/homebrew/bin/brew",
            ytDlpIsHomebrew: true,
            version: "1"
        )
        XCTAssertEqual(ToolStatus.updateArguments(brewed), ["/opt/homebrew/bin/brew", "upgrade", "yt-dlp"])
        XCTAssertNil(ToolStatus.message(for: brewed))
        XCTAssertEqual(ToolStatus.footer(tools: brewed, ready: true, notice: nil), "yt-dlp 1")

        let standalone = LocatedTools(
            ytDlp: "/usr/local/bin/yt-dlp",
            ffmpeg: "/usr/local/bin/ffmpeg",
            brew: "/opt/homebrew/bin/brew",
            ytDlpIsHomebrew: false,
            version: "1"
        )
        XCTAssertEqual(ToolStatus.updateArguments(standalone), ["/usr/local/bin/yt-dlp", "-U"])
    }

    func testSearchOrder() {
        let both = ToolLocator.find(named: "yt-dlp", pathEnv: "/custom", exists: { path in
            path == "/opt/homebrew/bin/yt-dlp" || path == "/custom/yt-dlp"
        })
        XCTAssertEqual(both, "/opt/homebrew/bin/yt-dlp")

        let onPath = ToolLocator.find(named: "yt-dlp", pathEnv: "/custom:/usr/bin", exists: { $0 == "/custom/yt-dlp" })
        XCTAssertEqual(onPath, "/custom/yt-dlp")

        let intel = ToolLocator.find(named: "yt-dlp", pathEnv: "/usr/bin:/bin", exists: { $0 == "/usr/local/bin/yt-dlp" })
        XCTAssertEqual(intel, "/usr/local/bin/yt-dlp")
    }

    func testChildPathPutsHomebrewFirstWithoutDuplicates() {
        let path = ToolLocator.childPATH(existing: "/usr/bin:/opt/homebrew/bin:/bin")
        XCTAssertTrue(path.hasPrefix("/opt/homebrew/bin:/usr/local/bin:"))
        XCTAssertEqual(path.split(separator: ":").filter { $0 == "opt/homebrew/bin" || $0 == "/opt/homebrew/bin" }.count, 1)
    }

    func testHomebrewCellarDetection() {
        XCTAssertTrue(ToolLocator.isHomebrewBinary(resolvedPath: "/opt/homebrew/Cellar/yt-dlp/2026.1.1/bin/yt-dlp"))
        XCTAssertTrue(ToolLocator.isHomebrewBinary(resolvedPath: "/usr/local/Cellar/ffmpeg/1/bin/ffmpeg"))
        XCTAssertFalse(ToolLocator.isHomebrewBinary(resolvedPath: "/Users/me/bin/yt-dlp"))
    }

    func testAbbreviateHome() {
        XCTAssertEqual(PathDisplay.abbreviate("/Users/me/Downloads", home: "/Users/me"), "~/Downloads")
        XCTAssertEqual(PathDisplay.abbreviate("/Users/me", home: "/Users/me"), "~")
        XCTAssertEqual(PathDisplay.abbreviate("/tmp", home: "/Users/me"), "/tmp")
    }

    func testShortFailureKeepsTheLastLine() {
        XCTAssertEqual(ToolStatus.shortFailure("Update failed", output: "a\n\nbrew: locked"), "Update failed. brew: locked")
        XCTAssertEqual(ToolStatus.shortFailure("Install failed", output: "  \n"), "Install failed.")
    }

    func testProcessIdentityMatchesThisProcess() {
        let pid = getpid()
        let started = ProcessIdentity.startSeconds(pid: pid)
        XCTAssertNotNil(started)
        XCTAssertTrue(ProcessIdentity.matches(pid: pid, started: started!))
        XCTAssertFalse(ProcessIdentity.matches(pid: pid, started: started! &+ 9))
    }

    func testEchoAndCancel() throws {
        let buffer = LineBuffer()
        let echo = try SpawnedProcess.launch(
            executable: "/bin/echo",
            arguments: ["hello"],
            environment: ["PATH": "/usr/bin:/bin"],
            directory: "/tmp",
            onLine: { buffer.append($0) }
        )
        XCTAssertEqual(echo.waitForExit(), 0)
        XCTAssertEqual(buffer.drain(), ["hello"])

        let sleep = try SpawnedProcess.launch(
            executable: "/bin/sleep",
            arguments: ["60"],
            environment: ["PATH": "/usr/bin:/bin"],
            directory: "/tmp",
            onLine: { _ in }
        )
        XCTAssertEqual(getpgid(sleep.pid), sleep.pid)
        let started = Date()
        sleep.cancel()
        let code = sleep.waitForExit()
        XCTAssertNotEqual(code, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testCancelKillsTheProcessGroup() throws {
        let before = commandPIDs(containing: "sleep 60")
        let process = try SpawnedProcess.launch(
            executable: "/bin/bash",
            arguments: ["-c", "sleep 60 & wait"],
            environment: ["PATH": "/usr/bin:/bin"],
            directory: "/tmp",
            onLine: { _ in }
        )
        Thread.sleep(forTimeInterval: 0.3)
        let during = commandPIDs(containing: "sleep 60").subtracting(before)
        XCTAssertFalse(during.isEmpty)
        process.cancel()
        _ = process.waitForExit()
        let leftover = commandPIDs(containing: "sleep 60").intersection(during)
        XCTAssertTrue(leftover.isEmpty)
    }

    func testTerminateOwnedDoesNotKillAMismatchedStartTime() throws {
        let process = try SpawnedProcess.launch(
            executable: "/bin/sleep",
            arguments: ["60"],
            environment: ["PATH": "/usr/bin:/bin"],
            directory: "/tmp",
            onLine: { _ in }
        )
        let started = try XCTUnwrap(ProcessIdentity.startSeconds(pid: process.pid))
        ProcessIdentity.terminateOwned(pid: process.pid, started: started &+ 5)
        XCTAssertEqual(kill(process.pid, 0), 0)
        ProcessIdentity.terminateOwned(pid: process.pid, started: started)
        let code = process.waitForExit()
        XCTAssertNotEqual(code, 0)
    }

    func testLiveFfmpegIsFoundInHomebrewWhenPresent() {
        guard let path = ToolLocator.find(named: "ffmpeg") else { return }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        XCTAssertTrue(path == "/opt/homebrew/bin/ffmpeg" || path == "/usr/local/bin/ffmpeg" || path.contains("/"))
        XCTAssertTrue(ToolLocator.isHomebrewBinary(resolvedPath: resolved))
    }

    private func sampleJob(mode: DownloadMode, quality: VideoQuality, audioFormat: AudioFormat) -> DownloadJob {
        DownloadJob(
            id: UUID(),
            sequence: 1,
            url: "https://example.com/watch?v=abc",
            mode: mode,
            quality: quality,
            audioFormat: audioFormat,
            destination: "/Users/me/My Downloads",
            status: .queued,
            title: "",
            error: "",
            filePath: nil,
            percent: nil,
            speed: "",
            eta: "",
            added: Date(timeIntervalSince1970: 1_700_000_000),
            finished: nil,
            pid: nil,
            pidStarted: nil
        )
    }

    private func commandPIDs(containing needle: String) -> Set<Int32> {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return []
        }
        // Drain before wait. A full pipe stalls ps, and waiting first deadlocks the test.
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        task.waitUntilExit()
        var found = Set<Int32>()
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains(needle), let token = trimmed.split(separator: " ").first, let pid = Int32(token) else {
                continue
            }
            found.insert(pid)
        }
        return found
    }
}
