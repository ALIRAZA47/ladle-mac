import AppKit
import LadleKit
import SwiftUI

/// Owns the main and settings windows (AppKit windows hosting SwiftUI, for full control of the
/// Molten chrome), and handles links, files, reopening and quitting.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: AppModel { AppModel.shared }
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var pendingURLs: [URL] = []
    private var launched = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // A regular app with a Dock icon and menus, even though its only SwiftUI scene is the
        // menu bar extra (the windows are AppKit windows).
        NSApp.setActivationPolicy(.regular)
        Typeface.registerBundledFonts()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosting unit tests: no downloads, windows, login item or update checks.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        model.showMainWindow = { [weak self] in self?.showMainWindow() }
        model.showSettingsWindow = { [weak self] in self?.showSettingsWindow() }
        model.start()
        launched = true
        if !pendingURLs.isEmpty {
            model.open(urls: pendingURLs)
            pendingURLs.removeAll()
        }
        // Started by the browser helper, or for a link: stay in the background.
        let background = CommandLine.arguments.contains(BridgeIPC.backgroundLaunchArgument)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let handOffJustArrived = Date().timeIntervalSince(self.model.lastHandOff) < 2
                if !background && !handOffJustArrived { self.showMainWindow() }
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if launched {
            model.open(urls: urls)
        } else {
            pendingURLs.append(contentsOf: urls)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if model.settings.watchClipboard { model.clipboard.check() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.isTerminating { return .terminateNow }
        model.isTerminating = true
        Task { @MainActor in
            // Downloads stop where they are; they resume on the next launch.
            await self.model.prepareForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: Windows

    func showMainWindow() {
        if mainWindow == nil {
            let root = Themed { MainWindowView() }
                .environmentObject(model)
            let hosting = NSHostingView(rootView: root)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Ladle"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            // An empty unified toolbar moves the traffic lights down into the sidebar, as designed.
            window.toolbar = NSToolbar(identifier: "LadleMain")
            window.toolbarStyle = .unified
            window.titlebarSeparatorStyle = .none
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 1040, height: 640)
            window.contentView = hosting
            window.setFrameAutosaveName("LadleMainWindow")
            if !window.setFrameUsingName("LadleMainWindow") { window.center() }
            window.delegate = self
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSettingsWindow() {
        if settingsWindow == nil {
            let root = Themed { SettingsView() }
                .environmentObject(model)
            let hosting = NSHostingView(rootView: root)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 812, height: 592),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Settings"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
