import Cocoa
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var browserLoginWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private let folderStore = DownloadFolderStore(defaults: .standard)
    private let popover = NSPopover()
    private let managerStorage = OwnershipBoundResource<DownloadManager>()
    private var manager: DownloadManager {
        guard let managerStorage = managerStorage.value else { preconditionFailure("Download state requires menu-bar ownership") }
        return managerStorage
    }
    private static func makeManager() -> DownloadManager {
        #if DROPLET_PREVIEW
        if let raw = Bundle.main.object(forInfoDictionaryKey: "DropletPreviewURL") as? String,
           let url = URL(string: raw), url.scheme == "http", url.host == "127.0.0.1",
           let path = Bundle.main.object(forInfoDictionaryKey: "DropletPreviewDownloads") as? String,
           path.hasPrefix(NSHomeDirectory() + "/Library/Developer/Droplet/UIQA/") {
            var environment = DownloadEnvironment.live
            environment.downloadsFolder = URL(fileURLWithPath: path, isDirectory: true)
            environment.readClipboardURL = { url }
            let fixtureRoot = environment.downloadsFolder.deletingLastPathComponent()
            return DownloadManager(environment: environment,
                trialStore: TrialFileStore(directory: fixtureRoot.appendingPathComponent("Trial")))
        }
        #endif
        return DownloadManager()
    }
    private var phaseCancellable: AnyCancellable?
    private var lastCloseAt = Date.distantPast
    private var isActivated = false
    private let instanceLock = SingleInstanceLock()
    private var startupFailureShown = false
    private var dormantTimer: Timer?
    #if DROPLET_PREVIEW
    private var previewWindow: NSWindow?
    private var previewPopoverOpens = 0
    private var previewPopoverCloses = 0
    #endif

    /// The launchd job label of the KeepAlive LaunchAgent that autostarts us.
    static let launchAgentLabel = "com.quentinthiessen.droplet"

    /// True when launchd started this process (our KeepAlive LaunchAgent)
    /// rather than the user opening the app. launchd sets XPC_SERVICE_NAME to
    /// the job label; Finder / `open` launches leave it unset or "0".
    static let launchedByLaunchd: Bool = {
        #if DROPLET_PREVIEW
        if CommandLine.arguments.contains("--preview-dormant") { return true }
        #endif
        guard let name = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] else { return false }
        return name == launchAgentLabel
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DROPLET_PREVIEW
        recordPreviewLifecycle("launched")
        #endif
        Self.debugLog("launched by launchd: \(Self.launchedByLaunchd) (XPC_SERVICE_NAME="
            + "\(ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] ?? "unset"))")

        // Preserve compatibility with an older installed instance that has no
        // kernel lock. New instances additionally acquire the lock below, so
        // delayed NSWorkspace registration cannot create two menu-bar owners.
        if let winner = instanceToYieldTo() {
            if Self.launchedByLaunchd {
                // Exiting would be pointless: the LaunchAgent has KeepAlive=true
                // and would respawn us straight into this same check, forever.
                // Hold the job slot dormant instead (no menu bar, no UI) and
                // take the menu bar over if the other instance ever goes away.
                Self.debugLog("instance pid \(winner.processIdentifier) owns the menu bar; staying dormant for launchd")
                becomeDormant()
                return
            }
            Self.debugLog("instance pid \(winner.processIdentifier) owns the menu bar; exiting")
            exit(0)
        }

        guard acquireMenuBarOwnership() else {
            if Self.launchedByLaunchd { becomeDormant() } else { exit(0) }
            return
        }
        activate()
    }

    private func acquireMenuBarOwnership() -> Bool {
        do {
            let url = try SingleInstanceLock.runtimeURL(bundleID: Bundle.main.bundleIdentifier ?? "local.droplet.development")
            let result = instanceLock.acquire(at: url)
            if case .failed(let code) = result {
                Self.debugLog("instance lock unavailable: \(code)")
                showStartupFailure()
            }
            managerStorage.initialize(ownership: result, factory: Self.makeManager)
            return result == .acquired
        } catch {
            Self.debugLog("instance lock path unavailable")
            showStartupFailure()
            return false
        }
    }

    private func showStartupFailure() {
        guard !startupFailureShown else { return }
        startupFailureShown = true
        let alert = NSAlert()
        alert.messageText = "Droplet couldn't start safely"
        alert.informativeText = "Droplet could not access its startup lock in your Application Support folder. Check that your user account can write there, then reopen Droplet."
        alert.addButton(withTitle: "Close")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Builds the menu-bar item and everything behind it. Runs exactly once,
    /// either at launch or later if this instance was dormant and inherits.
    private func activate() {
        guard !isActivated else { return }
        isActivated = true
        #if DROPLET_PREVIEW
        // An explicit fixture destination must remain isolated from preferences.
        if Bundle.main.object(forInfoDictionaryKey: "DropletPreviewDownloads") == nil {
            manager.restoreDownloadsFolder(from: folderStore)
        }
        #else
        manager.restoreDownloadsFolder(from: folderStore)
        #endif
        #if DROPLET_PREVIEW
        recordPreviewLifecycle("activate-begin")
        #endif

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "drop.fill", accessibilityDescription: "Droplet")
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        statusItem = item
        Self.debugLog("menu bar activated")
        #if DROPLET_PREVIEW
        recordPreviewLifecycle("status-item-created")
        #endif

        let root = MainView(
            manager: manager,
            onOpenDownloads: { [weak self] in self?.openDownloads() },
            onBrowserLogin: { [weak self] in self?.presentBrowserLogin() },
            onQuit: { [weak self] in self?.quitApp() },
            onClose: { [weak self] in self?.popover.performClose(nil) },
            onSettings: { [weak self] in self?.presentSettings() },
            onOpenSavedFile: { [weak self] in self?.openSavedFile() }
        )
        #if DROPLET_PREVIEW
        let hostedRoot = root.modifier(PreviewAccessibilityModifier())
        #else
        let hostedRoot = root
        #endif
        let host = NSHostingController(rootView: hostedRoot)
        host.sizingOptions = []          // fixed bubble size, no jumping
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 320, height: 420)
        popover.behavior = .transient    // click anywhere else to dismiss
        popover.animates = true
        popover.delegate = self

        phaseCancellable = manager.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in self?.updateStatusIcon(for: phase) }

        if !UserDefaults.standard.bool(forKey: "welcomeSeen.v1") {
            DispatchQueue.main.async { [weak self] in self?.presentWelcome() }
        }

        #if DROPLET_PREVIEW
        // A QA-only window hosts the exact same view for accessibility tools
        // that cannot select a menu-bar-only app. No user clipboard is exposed.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if Bundle.main.object(forInfoDictionaryKey: "DropletPreviewURL") != nil {
                self.manager.beginSession()
            } else {
                self.manager.clipboardURL = URL(string: "https://example.com/your-video")
            }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 560),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Droplet Preview"
            let preview = VStack(spacing: 0) {
                hostedRoot
                HStack {
                    ForEach([DownloadStage.fetching, .video, .audio, .merging, .finalizing], id: \.self) { stage in
                        Button(stage == .fetching ? "Fetch" : stage == .video ? "Video" : stage == .audio ? "Audio" : stage == .merging ? "Merge" : "Finish") {
                            self.manager.phase = .downloading
                            self.manager.title = "Preview — no download running"
                            self.manager.stage = stage
                            self.manager.progressKnown = stage == .video || stage == .audio
                            self.manager.progress = stage == .audio ? 0.99 : stage == .video ? 0.42 : 0
                        }
                    }
                }.font(.system(size: 10)).padding(8)
                Button("Preview login error") {
                    self.manager.phase = .failed("This video requires a signed-in session.")
                }.font(.system(size: 10)).padding(.bottom, 6)
                HStack {
                    Button("Open popover") { self.togglePopover(nil) }
                    Button("System quit") { NSApp.terminate(nil) }
                }.font(.system(size: 10)).padding(.bottom, 8)
                HStack {
                    Button("Launch duplicate") { self.launchPreviewInstance(dormant: false) }
                    Button("Launch dormant") { self.launchPreviewInstance(dormant: true) }
                }.font(.system(size: 10)).padding(.bottom, 8)
                PreviewAppearanceControls()
            }
            let previewHost = NSHostingController(rootView: preview.frame(width: 320, height: 620))
            previewHost.sizingOptions = []
            window.contentViewController = previewHost
            window.setContentSize(NSSize(width: 320, height: 620))
            window.isReleasedWhenClosed = false
            window.center()
            self.previewWindow = window
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.recordPreviewLifecycle("preview-window-shown")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.recordPreviewLifecycle("preview-window-settled")
            }
        }
        #endif

        #if DROPLET_PREVIEW
        // Development-only self-test for the engine updater: --smoke-update
        if CommandLine.arguments.contains("--smoke-update") {
            manager.updateDownloader()
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                if let note = self?.manager.updateNote { Self.debugLog("update note: '\(note)'") }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                if let note = self?.manager.updateNote { Self.debugLog("note after clear: '\(note)'") }
                self?.quitApp()
            }
        }

        // Hidden self-test: launch with "--smoke-test" to verify the quit
        // path kills a live download completely (used by build verification).
        // Required: --smoke-url=<url>. Optional: --smoke-quit=<seconds>.
        if CommandLine.arguments.contains("--smoke-test") {
            let urlArg = CommandLine.arguments
                .first { $0.hasPrefix("--smoke-url=") }?
                .replacingOccurrences(of: "--smoke-url=", with: "")
            // No implicit public download. Only an explicitly supplied URL runs.
            guard let urlArg, let smokeURL = URL(string: urlArg) else {
                Self.debugLog("--smoke-test requires --smoke-url")
                return
            }
            manager.clipboardURL = smokeURL
            manager.startDownload()

            let quitAfter = CommandLine.arguments
                .first { $0.hasPrefix("--smoke-quit=") }
                .map { $0.replacingOccurrences(of: "--smoke-quit=", with: "") }
                .flatMap { Double($0) } ?? 2.5

            DispatchQueue.main.asyncAfter(deadline: .now() + quitAfter) { [weak self] in
                if let phase = self?.manager.phase { Self.debugLog("final phase: \(phase)") }
                self?.quitApp()
            }
        }
        #endif
    }

    #if DROPLET_PREVIEW
    private func recordPreviewLifecycle(_ event: String) {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Droplet/UIQA/Lifecycle", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("\(getpid()).jsonl")
            let record: [String: Any] = ["event": event, "pid": getpid(), "activated": isActivated,
                "statusItem": statusItem != nil, "previewWindow": previewWindow != nil,
                "windowVisible": previewWindow?.isVisible ?? false, "appHidden": NSApp.isHidden,
                "windowCount": NSApp.windows.count, "mainThread": Thread.isMainThread]
            var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            data.append(10)
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch { Self.debugLog("preview lifecycle record failed") }
    }

    private func launchPreviewInstance(dormant: Bool) {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.addsToRecentItems = false
        config.activates = false
        config.arguments = dormant ? ["--preview-dormant"] : []
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { [weak self] app, error in
            DispatchQueue.main.async {
                self?.previewWindow?.title = app.map { "Droplet Preview — launched PID \($0.processIdentifier)" }
                    ?? "Droplet Preview — launch result \((error as NSError?)?.code ?? 0)"
            }
        }
    }
    #endif

    /// Debug helper — prints to stdout only when DROPLET_DEBUG=1 is set.
    static func debugLog(_ message: String) { DropletLog.debug(message) }

    private func updateStatusIcon(for phase: DownloadManager.Phase) {
        guard let button = statusItem?.button else { return }
        button.toolTip = phase == .downloading ? "Droplet — downloading" : phase == .done ? "Droplet — video saved" : "Droplet — open video downloader"
        button.setAccessibilityLabel(button.toolTip)
        switch phase {
        case .downloading:
            button.image = NSImage(systemSymbolName: "drop.circle.fill", accessibilityDescription: nil)
            button.contentTintColor = NSColor.controlAccentColor
        case .done:
            button.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
            button.contentTintColor = NSColor.systemGreen
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
                guard let self, case .done = self.manager.phase else { return }
                self.setBaseIcon()
            }
        default:
            setBaseIcon()
        }
    }

    private func setBaseIcon() {
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "drop.fill", accessibilityDescription: "Droplet")
        button.contentTintColor = nil
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else if Date().timeIntervalSince(lastCloseAt) > 0.3 {
            manager.beginSession()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func popoverDidShow(_ notification: Notification) {
        #if DROPLET_PREVIEW
        previewPopoverOpens += 1
        updatePreviewPopoverTitle()
        #endif
    }

    #if DROPLET_PREVIEW
    private func updatePreviewPopoverTitle() {
        previewWindow?.title = "Droplet Preview — menu opened \(previewPopoverOpens), closed \(previewPopoverCloses)"
    }
    #endif

    func popoverDidClose(_ notification: Notification) {
        #if DROPLET_PREVIEW
        previewPopoverCloses += 1
        updatePreviewPopoverTitle()
        #endif
        lastCloseAt = Date()
        // if a download is running it just continues in the background —
        // the menu-bar icon stays switched to the "active" droplet
    }

    private func presentBrowserLogin() {
        guard let url = manager.browserLoginURL else { return }
        popover.performClose(nil)
        // A fresh form has no remembered browser/profile consent.
        browserLoginWindow?.close()
        let window = BrowserLoginPrompt.window(for: url, onConsent: { [weak self] consent in
            guard let self else { return }
            self.browserLoginWindow?.close()
            self.browserLoginWindow = nil
            self.manager.startDownload(using: consent)
            self.reopenAfterBrowserLogin()
        }, onCancel: { [weak self] in
            self?.browserLoginWindow?.close()
            self?.browserLoginWindow = nil
            self?.reopenAfterBrowserLogin()
        })
        browserLoginWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func reopenAfterBrowserLogin() {
        #if DROPLET_PREVIEW
        if let previewWindow {
            previewWindow.makeKeyAndOrderFront(nil)
            return
        }
        #endif
        if let button = statusItem?.button, !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func openDownloads() {
        let target = manager.result?.fileURL ?? manager.downloadsFolder
        guard FileManager.default.fileExists(atPath: target.path) else {
            let alert = NSAlert()
            alert.messageText = "This saved location is unavailable"
            alert.informativeText = "The file or folder may have been moved or removed. Choose another save folder in Settings, or restore the original location."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        if manager.result != nil {
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } else if !NSWorkspace.shared.open(target) {
            let alert = NSAlert()
            alert.messageText = "The download folder could not be opened"
            alert.informativeText = "Check that the folder is available and that your user account can access it."
            alert.runModal()
        }
    }

    private func openSavedFile() {
        guard let result = manager.result else { return }
        guard FileManager.default.fileExists(atPath: result.fileURL.path),
              NSWorkspace.shared.open(result.fileURL) else {
            let alert = NSAlert()
            alert.messageText = "This video could not be opened"
            alert.informativeText = "The file may have been moved or removed, or no compatible video player is available. Check the save folder in Finder."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
    }

    private func presentSettings() {
        popover.performClose(nil)
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 560),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Droplet Settings"
        window.isReleasedWhenClosed = false
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        window.contentViewController = NSHostingController(rootView: SettingsView(manager: manager,
            onChooseFolder: { [weak self] in self?.chooseDownloadFolder() },
            onClose: { [weak window] in window?.close() },
            onWelcome: { [weak self] in self?.presentWelcome() }, version: "\(version) (\(build))"))
        settingsWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentWelcome() {
        if let welcomeWindow {
            welcomeWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 420),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Welcome to Droplet"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: WelcomeView(onContinue: { [weak window] in
            UserDefaults.standard.set(true, forKey: "welcomeSeen.v1")
            window?.close()
        }))
        welcomeWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func chooseDownloadFolder() {
        guard manager.phase != .downloading, let settingsWindow else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose where Droplet saves videos"
        panel.prompt = "Use this folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = manager.downloadsFolder
        panel.beginSheetModal(for: settingsWindow) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            do { try self.manager.chooseDownloadsFolder(url, store: self.folderStore) }
            catch {
                let alert = NSAlert()
                alert.messageText = "This folder could not be selected"
                alert.informativeText = "Choose an available folder you can write to. Your previous choice has been preserved."
                alert.beginSheetModal(for: settingsWindow)
            }
        }
    }

    // MARK: quitting — full shutdown, no background leftovers

    /// There is a launchd LaunchAgent (~/Library/LaunchAgents/com.quentinthiessen.droplet.plist)
    /// with KeepAlive=true that restarts this app ~2s after it exits.
    /// Booting the job out tells launchd to stand down — quitting then REALLY quits.
    /// (The agent reloads at next login, so autostart still works after reboot.)
    private func bootOutKeepAliveAgent() {
        // A side-by-side preview must never unload the user's installed app.
        guard Bundle.main.object(forInfoDictionaryKey: "DropletIsPreview") as? Bool != true else { return }
        let uid = getuid()
        let label = Self.launchAgentLabel
        let commands: [[String]] = [
            ["bootout", "gui/\(uid)/\(label)"],
            ["remove", label],
            ["unload", NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"],
        ]
        for args in commands {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
    }

    /// Another running Droplet that outranks this one, if any.
    ///
    /// The ranking — earliest launch wins, PID breaks ties — is a *total
    /// order*, so of two instances racing each other exactly one sees the
    /// other as the winner. (The old check was symmetric: two simultaneous
    /// launches each saw the other and both exited, leaving no app at all.)
    private func instanceToYieldTo() -> NSRunningApplication? {
        let myPID = getpid()
        let myRank = ProcessInspector.rank(of: myPID)
        return NSWorkspace.shared.runningApplications.first { app in
            guard app.bundleIdentifier == Bundle.main.bundleIdentifier,
                  app.processIdentifier != myPID else { return false }
            return ProcessInspector.rank(of: app.processIdentifier) < myRank
        }
    }

    /// Stay running with no UI at all, watching for the instance that owns the
    /// menu bar to go away. Used only when launchd owns this process: exiting
    /// here would just trigger an endless respawn loop against the KeepAlive
    /// job, so the process holds the job slot idle instead.
    ///
    /// Polled rather than driven by NSWorkspace.didTerminateApplication:
    /// that notification does not fire reliably for an instance that was not
    /// started through LaunchServices, or that was killed outright — the two
    /// cases where inheriting matters most.
    private func becomeDormant() {
        #if DROPLET_PREVIEW
        recordPreviewLifecycle("dormant")
        #endif
        let timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.inheritMenuBarIfVacant() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dormantTimer = timer
    }

    /// Promotes this dormant instance once no other Droplet is left.
    private func inheritMenuBarIfVacant() {
        guard !isActivated, instanceToYieldTo() == nil, acquireMenuBarOwnership() else { return }
        dormantTimer?.invalidate()
        dormantTimer = nil
        Self.debugLog("menu bar is vacant — dormant instance taking over")
        activate()
    }

    /// Force-terminate every other running Droplet instance so no duplicate
    /// menu-bar droplets survive. Only used in the quit path.
    private func terminateOtherDropletInstances() {
        let myPID = getpid()
        for app in NSWorkspace.shared.runningApplications
        where app.bundleIdentifier == Bundle.main.bundleIdentifier
           && app.processIdentifier != myPID {
            app.forceTerminate()
        }
    }

    private func quitApp() {
        popover.performClose(nil)
        managerStorage.value?.shutdownForQuit()     // dormant instances have no download state
        managerStorage.value?.sweepBackgroundProcesses()
        bootOutKeepAliveAgent()               // tell launchd to stand down (may
                                              // SIGTERM us if launchd owns us —
                                              // cleanup is already done by then)
        terminateOtherDropletInstances()      // no duplicate icons either
        fflush(stdout)
        exit(0)                               // unconditional: app can never survive
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // any other quit path (logout, etc.) runs the same full shutdown
        quitApp()
        return .terminateNow
    }
}
