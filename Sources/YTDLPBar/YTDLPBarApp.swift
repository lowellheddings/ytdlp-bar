import AppKit
import Darwin
import SwiftUI
import YTDLPBarCore

@main
struct YTDLPBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    init() {
        ProcessInfo.processInfo.disableSuddenTermination()
        guard InstanceLock.shared.acquire() else {
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            // Observing the model keeps the status item in step with the running percent.
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Deliver SIGTERM on the main queue so Quit still saves the queue. The default action
        // would kill the process before applicationWillTerminate runs.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            NSApp.terminate(nil)
        }
        source.resume()
        termSource = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared?.prepareForQuit()
    }
}

/// One menu bar icon. A second launch finds the lock held and leaves.
final class InstanceLock: @unchecked Sendable {
    static let shared = InstanceLock()
    private var fd: Int32 = -1

    func acquire() -> Bool {
        let directory = JobStore.applicationSupport().directory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            return true
        }
        let url = directory.appendingPathComponent("instance.lock")
        fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            return false
        }
        _ = ftruncate(fd, 0)
        let note = "\(getpid())\n"
        _ = note.withCString { pointer in
            write(fd, pointer, strlen(pointer))
        }
        return true
    }
}
