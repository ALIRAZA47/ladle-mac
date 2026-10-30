// LadleBridge: the native messaging host for Ladle's extension in Chrome, Arc, Edge, Brave and Firefox
// (host name me.alirazakhan.ladle). The browser starts it and talks over stdin/stdout with
// length-prefixed JSON. Each message goes to the app's local message port; the app answers
// right away. Messages from the app ("Let the browser handle it", new settings) arrive on this
// helper's own port and are passed to the browser.

import AppKit
import CoreFoundation
import Foundation
import LadleKit

enum Bridge {
    static let outputLock = NSLock()
    static let pushPortName = BridgeIPC.helperPortName(pid: getpid())
    static var pushPort: CFMessagePort?

    /// The browser that started us, from our parent process ("Arc", "Chrome", "Firefox"…).
    static let browser: String = {
        guard let parent = NSRunningApplication(processIdentifier: getppid()), let name = parent.localizedName else { return "" }
        var short = name
        for prefix in ["Google ", "Microsoft "] where short.hasPrefix(prefix) { short.removeFirst(prefix.count) }
        if short.hasSuffix(" Browser") { short.removeLast(" Browser".count) }
        return short
    }()

    static func write(_ json: Data) {
        outputLock.lock()
        defer { outputLock.unlock() }
        FileHandle.standardOutput.write(NativeMessaging.frame(json))
    }

    static func reply(_ message: BridgeReply) {
        if let data = try? NativeMessaging.encode(message) { write(data) }
    }

    // MARK: The app

    static func appIsListening() -> Bool {
        guard let remote = CFMessagePortCreateRemote(nil, BridgeIPC.appPortName as CFString) else { return false }
        CFMessagePortInvalidate(remote)
        return true
    }

    static var appURL: URL? {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" { return bundle }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: BridgeIPC.appBundleIdentifier)
    }

    /// Starts Ladle in the background if needed and waits (up to 15 s) for it to listen.
    static func ensureApp() -> Bool {
        if appIsListening() { return true }
        guard let url = appURL else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.arguments = [BridgeIPC.backgroundLaunchArgument]
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
        for _ in 0..<60 {
            usleep(250_000)
            if appIsListening() { return true }
        }
        return false
    }

    static func sendToApp(_ envelope: BridgeEnvelope) -> Data? {
        guard let remote = CFMessagePortCreateRemote(nil, BridgeIPC.appPortName as CFString),
              let data = try? JSONEncoder().encode(envelope) else { return nil }
        defer { CFMessagePortInvalidate(remote) }
        var response: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(
            remote,
            BridgeIPC.requestMessageID,
            data as CFData,
            5,
            20,
            CFRunLoopMode.defaultMode.rawValue,
            &response
        )
        guard status == kCFMessagePortSuccess, let response else { return nil }
        return response.takeRetainedValue() as Data
    }

    /// Settings the app left for us, to answer `hello` without starting Ladle.
    static func storedSettings() -> BrowserSettingsSnapshot? {
        guard let data = try? Data(contentsOf: AppPaths.standard().browserSettings) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BrowserSettingsSnapshot.self, from: data)
    }

    // MARK: Messages from the browser

    static func handle(_ frame: Data) {
        guard let request = try? JSONDecoder().decode(BridgeRequest.self, from: frame) else {
            reply(BridgeReply(replyTo: nil, ok: false, error: "unreadable"))
            return
        }
        if request.type == "hello" && !appIsListening() {
            // Without the trust token: that's for Safari's extension, which reads the file itself.
            var stored = storedSettings()
            stored?.token = ""
            reply(BridgeReply(replyTo: request.id, ok: true, settings: stored))
            return
        }
        guard ensureApp() else {
            reply(BridgeReply(replyTo: request.id, ok: false, error: "Ladle didn’t start"))
            return
        }
        let envelope = BridgeEnvelope(replyPort: pushPortName, browser: browser.isEmpty ? nil : browser, request: request)
        if let answer = sendToApp(envelope) {
            write(answer)
        } else {
            reply(BridgeReply(replyTo: request.id, ok: false, error: "Ladle didn’t answer"))
        }
    }

    // MARK: Messages from the app

    static func listenForPushes() {
        var context = CFMessagePortContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        let callback: CFMessagePortCallBack = { _, _, data, _ in
            if let data { Bridge.write(data as Data) }
            return nil
        }
        guard let port = CFMessagePortCreateLocal(nil, pushPortName as CFString, callback, &context, nil) else { return }
        pushPort = port
        if let source = CFMessagePortCreateRunLoopSource(nil, port, 0) {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
        }
    }
}

Bridge.listenForPushes()

Thread.detachNewThread {
    var buffer = Data()
    while true {
        let chunk = FileHandle.standardInput.availableData
        if chunk.isEmpty { exit(0) }
        buffer.append(chunk)
        do {
            for frame in try NativeMessaging.takeFrames(from: &buffer) {
                Bridge.handle(frame)
            }
        } catch {
            exit(1)
        }
    }
}

CFRunLoopRun()
