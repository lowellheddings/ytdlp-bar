import AppKit
import Combine
import Darwin
import SwiftUI
import YTDLPBarCore

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var model: AppModel?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var menuBarWatch: AnyCancellable?
    private var outsideClick: Any?
    private var termSource: DispatchSourceSignal?

    /// The synthesized @main only calls NSApplicationMain. This bundle has no main nib,
    /// so AppKit never installs the delegate: no status item, and LSUIElement means no
    /// Dock icon either. NSApplication.delegate is weak, so the instance has to stay
    /// retained for the whole run loop or it is dropped immediately.
    nonisolated static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            // A menu bar app has no windows. Automatic termination would quit it
            // right after launch, which is what "does not load" looks like.
            ProcessInfo.processInfo.disableAutomaticTermination("menu bar")
            ProcessInfo.processInfo.disableSuddenTermination()
            withExtendedLifetime(delegate) {
                app.run()
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableSuddenTermination()
        guard InstanceLock.shared.acquire() else {
            exit(0)
        }
        installQuitOnSignal()

        let model = AppModel()
        self.model = model

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePanel(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        let host = NSHostingController(rootView: PanelView(model: model))
        host.sizingOptions = [.preferredContentSize, .intrinsicContentSize]
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = host
        self.popover = popover

        menuBarWatch = model.$menuBarText.sink { [weak self] text in
            DispatchQueue.main.async {
                self?.applyMenuBar(text)
            }
        }
        applyMenuBar(model.menuBarText)
        installQuitMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared?.prepareForQuit()
    }

    func popoverDidClose(_ notification: Notification) {
        stopOutsideClick()
    }

    /// MenuBarExtra kept the open panel on its first drawing, so a job that started
    /// afterward never appeared. This popover is a normal SwiftUI host and stays live.
    @objc private func togglePanel(_ sender: Any?) {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if outsideClick == nil {
            outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in
                    self?.popover?.performClose(nil)
                }
            }
        }
    }

    private func stopOutsideClick() {
        if let outsideClick {
            NSEvent.removeMonitor(outsideClick)
            self.outsideClick = nil
        }
    }

    private func applyMenuBar(_ text: String) {
        guard let button = statusItem?.button else { return }
        let symbol = text.isEmpty ? "arrow.down.circle" : "arrow.down.circle.fill"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "YTDLP Bar")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
        button.title = text.isEmpty ? "" : " \(text)"
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.setAccessibilityLabel(text.isEmpty ? "YTDLP Bar" : "YTDLP Bar \(text)")
    }

    private func installQuitMenu() {
        let root = NSMenu()
        let appItem = NSMenuItem()
        root.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit YTDLP Bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = root
    }

    private func installQuitOnSignal() {
        // Deliver SIGTERM on the main queue so Quit still saves the queue. The default action
        // would kill the process before applicationWillTerminate runs.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
        source.resume()
        termSource = source
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
