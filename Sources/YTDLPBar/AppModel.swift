import AppKit
import Foundation
import YTDLPBarCore

@MainActor
final class AppModel: ObservableObject {
    static weak var shared: AppModel?

    @Published var mode: DownloadMode {
        didSet { settings.mode = mode }
    }
    @Published var quality: VideoQuality {
        didSet { settings.quality = quality }
    }
    @Published var audioFormat: AudioFormat {
        didSet { settings.audioFormat = audioFormat }
    }
    @Published var destination: String {
        didSet { settings.destination = destination }
    }
    @Published private(set) var queue: DownloadQueue
    @Published private(set) var menuBarText = ""
    @Published private(set) var tools: LocatedTools = .unknown
    @Published private(set) var toolsReady = false
    @Published private(set) var toolBusy = false
    @Published var notice: String?
    @Published var banner: String?

    private let settings: SettingsStore
    private let store: JobStore
    private let runner = QueueRunner()
    private(set) var acceptingWork = false
    private(set) var shuttingDown = false
    private var toolProcess: SpawnedProcess?

    var homePath: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    var destinationDisplay: String {
        PathDisplay.abbreviate(destination, home: homePath)
    }

    var footer: String {
        ToolStatus.footer(tools: tools, ready: toolsReady, notice: notice)
    }

    var showInstall: Bool {
        toolsReady && !toolBusy && ToolStatus.showsInstall(tools)
    }

    var showUpdate: Bool {
        toolsReady && tools.ytDlp != nil
    }

    var updateDisabled: Bool {
        toolBusy || queue.runningJob() != nil
    }

    init(settings: SettingsStore = SettingsStore(), store: JobStore = .applicationSupport()) {
        self.settings = settings
        self.store = store
        mode = settings.mode
        quality = settings.quality
        audioFormat = settings.audioFormat
        destination = settings.destination
        queue = DownloadQueue(jobs: store.load())
        AppModel.shared = self
        runner.model = self
        bootstrap()
    }

    func canPressDownload(link: String) -> Bool {
        toolsReady && tools.ytDlp != nil && !toolBusy && !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @discardableResult
    func enqueue(link: String) -> Bool {
        guard acceptingWork, !shuttingDown, !toolBusy else { return false }
        guard tools.ytDlp != nil else { return false }
        guard let url = LinkCheck.normalize(link) else {
            banner = "That isn't a link."
            return false
        }
        guard destination.hasPrefix("/") else {
            banner = "Choose a download folder."
            return false
        }
        queue.add(url: url, mode: mode, quality: quality, audioFormat: audioFormat, destination: destination)
        store.save(queue.jobs)
        banner = nil
        runner.kick()
        return true
    }

    func cancel(id: UUID) {
        guard queue.job(id: id)?.status == .running else { return }
        runner.cancelRunning()
        queue.finish(id: id, status: .cancelled, error: "", filePath: nil)
        store.save(queue.jobs)
        syncMenuBar()
    }

    func removeQueued(id: UUID) {
        guard queue.removeQueued(id: id) else { return }
        store.save(queue.jobs)
    }

    func clearFinished() {
        queue.clearFinished()
        store.save(queue.jobs)
    }

    func markRunning(id: UUID, pid: Int32, pidStarted: UInt64?) {
        guard !shuttingDown else { return }
        queue.markRunning(id: id, pid: pid, pidStarted: pidStarted)
        store.save(queue.jobs)
        syncMenuBar()
    }

    func noteProgress(id: UUID, percent: Double?, speed: String, eta: String) {
        guard !shuttingDown else { return }
        queue.noteProgress(id: id, percent: percent, speed: speed, eta: eta)
        syncMenuBar()
    }

    func noteTitle(id: UUID, title: String) {
        guard !shuttingDown else { return }
        if queue.noteTitle(id: id, title: title) {
            store.save(queue.jobs)
        }
    }

    func finish(id: UUID, status: JobStatus, error: String, filePath: String?) {
        guard !shuttingDown else { return }
        switch queue.job(id: id)?.status {
        case .running:
            break
        case .queued where status == .failed:
            // Spawn can fail before the job is marked running. Leave it failed, or the queue retries it forever.
            break
        default:
            return
        }
        queue.finish(id: id, status: status, error: error, filePath: filePath)
        store.save(queue.jobs)
        syncMenuBar()
    }

    func openDestination() {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination, isDirectory: &isDirectory), isDirectory.boolValue else {
            banner = "The download folder is not there."
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: destination))
    }

    func reveal(job: DownloadJob) {
        guard job.status == .done else { return }
        guard let path = job.filePath, !path.isEmpty else {
            banner = "That file is not in the queue."
            return
        }
        guard FileManager.default.fileExists(atPath: path) else {
            banner = "That file is not there anymore."
            return
        }
        banner = nil
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func pickDestination() {
        let panel = NSOpenPanel()
        panel.title = "Download folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: destination, isDirectory: true)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        NSApp.setActivationPolicy(.accessory)
        guard response == .OK, let url = panel.url else { return }
        destination = url.path
    }

    func clipboardLink() -> String? {
        guard let raw = NSPasteboard.general.string(forType: .string) else { return nil }
        return LinkCheck.normalize(raw)
    }

    func installTools() {
        guard !toolBusy, queue.runningJob() == nil, let arguments = ToolStatus.installArguments(tools) else { return }
        runTool(arguments, working: "Installing yt-dlp and ffmpeg…", failure: "Install failed")
    }

    func updateYTDLP() {
        guard !updateDisabled, let arguments = ToolStatus.updateArguments(tools) else { return }
        runTool(arguments, working: "Updating yt-dlp…", failure: "Update failed")
    }

    func prepareForQuit() {
        shuttingDown = true
        toolProcess?.killNow()
        runner.killRunning()
        _ = queue.takeInterrupted()
        store.saveSync(queue.jobs)
    }

    private func bootstrap() {
        let interrupted = queue.takeInterrupted()
        if !interrupted.isEmpty {
            store.saveSync(queue.jobs)
        }
        Task.detached { [interrupted] in
            for item in interrupted {
                ProcessIdentity.terminateOwned(pid: item.pid, started: item.started)
            }
            let located = ToolLocator.locate()
            var version: String?
            if let binary = located.ytDlp {
                version = ToolLocator.version(of: binary, timeout: 3)
            }
            await MainActor.run { [located, version] in
                self.applyTools(located, version: version)
            }
        }
    }

    private func applyTools(_ located: LocatedTools, version: String?) {
        guard !shuttingDown else { return }
        var located = located
        located.version = version
        tools = located
        toolsReady = true
        acceptingWork = true
        if tools.ytDlp != nil {
            runner.kick()
        }
    }

    private func runTool(_ arguments: [String], working: String, failure: String) {
        toolBusy = true
        notice = working
        let env = arguments.first == tools.brew ? ToolLocator.brewEnvironment() : ToolLocator.ytDlpEnvironment()
        Task.detached { [arguments, env] in
            let buffer = LineBuffer()
            let process: SpawnedProcess?
            do {
                process = try SpawnedProcess.launch(
                    executable: arguments[0],
                    arguments: Array(arguments.dropFirst()),
                    environment: env,
                    directory: NSTemporaryDirectory(),
                    onLine: { buffer.append($0) }
                )
            } catch {
                process = nil
            }
            let code: Int32
            let output: String
            if let process {
                await MainActor.run { self.toolProcess = process }
                code = process.waitForExit()
                output = buffer.drain().joined(separator: "\n")
            } else {
                code = 1
                output = "Could not start the command."
            }
            await MainActor.run {
                self.toolProcess = nil
                guard !self.shuttingDown else { return }
                self.finishTool(code: code, output: output, failure: failure)
            }
        }
    }

    private func finishTool(code: Int32, output: String, failure: String) {
        toolBusy = false
        let located = ToolLocator.locate()
        tools = located
        notice = code == 0 ? nil : ToolStatus.shortFailure(failure, output: output)
        Task.detached {
            let version = located.ytDlp.flatMap { ToolLocator.version(of: $0, timeout: 3) }
            await MainActor.run {
                guard !self.shuttingDown else { return }
                var refreshed = self.tools
                refreshed.version = version
                self.tools = refreshed
                self.toolsReady = true
                if code == 0 {
                    self.runner.kick()
                }
            }
        }
    }

    private func syncMenuBar() {
        let text: String
        if let job = queue.runningJob() {
            if let percent = job.percent {
                text = "\(Int(percent.rounded()))%"
            } else {
                text = "…"
            }
        } else {
            text = ""
        }
        if text != menuBarText {
            menuBarText = text
        }
    }
}

final class SettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var mode: DownloadMode {
        get { DownloadMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .video }
        set { defaults.set(newValue.rawValue, forKey: Keys.mode) }
    }

    var quality: VideoQuality {
        get { VideoQuality(rawValue: defaults.string(forKey: Keys.quality) ?? "") ?? .best }
        set { defaults.set(newValue.rawValue, forKey: Keys.quality) }
    }

    var audioFormat: AudioFormat {
        get { AudioFormat(rawValue: defaults.string(forKey: Keys.audioFormat) ?? "") ?? .keep }
        set { defaults.set(newValue.rawValue, forKey: Keys.audioFormat) }
    }

    var destination: String {
        get {
            let stored = defaults.string(forKey: Keys.destination) ?? ""
            if stored.isEmpty { return Self.defaultDestination }
            return stored
        }
        set { defaults.set(newValue, forKey: Keys.destination) }
    }

    static var defaultDestination: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
    }

    private enum Keys {
        static let mode = "mode"
        static let quality = "quality"
        static let audioFormat = "audioFormat"
        static let destination = "destination"
    }
}
