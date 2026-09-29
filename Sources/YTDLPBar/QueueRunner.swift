import Foundation
import YTDLPBarCore

/// Drains yt-dlp output off the main thread and applies it in small batches.
@MainActor
final class QueueRunner {
    weak var model: AppModel?
    private var loop: Task<Void, Never>?
    private var process: SpawnedProcess?
    private let lines = LineBuffer()
    private var filePath: String?
    private var fileTrusted = false
    private var log: [String] = []
    private var activeID: UUID?

    func kick() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func cancelRunning() {
        process?.cancel()
    }

    func killRunning() {
        process?.killNow()
    }

    private func runLoop() async {
        defer { loop = nil }
        while !Task.isCancelled {
            guard let model, model.acceptingWork, !model.toolBusy, model.tools.ytDlp != nil else { break }
            guard let job = model.queue.nextQueued() else { break }
            await run(job)
        }
        if let model, model.acceptingWork, !model.toolBusy, model.tools.ytDlp != nil, model.queue.nextQueued() != nil {
            kick()
        }
    }

    private func run(_ job: DownloadJob) async {
        guard let model else { return }
        guard let binary = model.tools.ytDlp else { return }
        filePath = nil
        fileTrusted = false
        log.removeAll(keepingCapacity: true)
        _ = lines.drain()

        let ffmpegDirectory = ToolLocator.ffmpegDirectory(from: model.tools.ffmpeg)
        let arguments: [String]
        do {
            arguments = try YTDLPArguments.make(job: job, ffmpegDirectory: ffmpegDirectory)
        } catch {
            model.finish(id: job.id, status: .failed, error: "This job has a link or folder the queue will not run.", filePath: nil)
            return
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: job.destination, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                model.finish(id: job.id, status: .failed, error: "The download folder is not a folder.", filePath: nil)
                return
            }
        } else {
            do {
                try FileManager.default.createDirectory(atPath: job.destination, withIntermediateDirectories: true)
            } catch {
                model.finish(id: job.id, status: .failed, error: "Could not create the download folder.", filePath: nil)
                return
            }
        }

        let buffer = lines
        let spawned: SpawnedProcess
        do {
            spawned = try SpawnedProcess.launch(
                executable: binary,
                arguments: arguments,
                environment: ToolLocator.ytDlpEnvironment(),
                directory: job.destination,
                onLine: { buffer.append($0) }
            )
        } catch {
            model.finish(id: job.id, status: .failed, error: "Could not start yt-dlp.", filePath: nil)
            return
        }

        process = spawned
        activeID = job.id
        let started = ProcessIdentity.startSeconds(pid: spawned.pid)
        model.markRunning(id: job.id, pid: spawned.pid, pidStarted: started)

        let poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.drain()
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }

        let code = await Task.detached { spawned.waitForExit() }.value
        poll.cancel()
        drain()
        process = nil
        activeID = nil
        guard !model.shuttingDown else { return }
        guard model.queue.job(id: job.id)?.status == .running else { return }

        if code == 0 {
            model.finish(id: job.id, status: .done, error: "", filePath: filePath)
        } else {
            model.finish(
                id: job.id,
                status: .failed,
                error: ErrorText.best(from: log, code: code),
                filePath: filePath
            )
        }
    }

    private func drain() {
        guard let model, !model.shuttingDown, let id = activeID else {
            _ = lines.drain()
            return
        }
        for line in lines.drain() {
            switch LineParser.parse(line) {
            case .progress(let percent, let speed, let eta, let title):
                model.noteProgress(id: id, percent: percent, speed: speed, eta: eta)
                if let title {
                    model.noteTitle(id: id, title: title)
                }
            case .title(let title):
                model.noteTitle(id: id, title: title)
            case .file(let path, let trusted):
                if trusted || !fileTrusted {
                    filePath = path
                    if trusted { fileTrusted = true }
                }
            case .log(let text):
                guard !text.isEmpty else { continue }
                if log.count == 80 { log.removeFirst() }
                log.append(text.count > 500 ? String(text.prefix(500)) : text)
            }
        }
    }
}
