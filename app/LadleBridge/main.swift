// LadleBridge: the native messaging host for Ladle's extension in Chrome, Arc, Dia, Edge, Brave and
// Firefox (host name me.alirazakhan.ladle). The browser starts it and talks over stdin/stdout with
// length-prefixed JSON. The helper keeps one connection to the app's local socket: each browser
// message goes down it, and the app's replies and pushes ("Let the browser handle it", new settings)
// come back up it and on to the browser. Before anything is sent, the process at the socket has to
// prove it's the Ladle this helper belongs to (PeerVerification); an impostor gets nothing.

import AppKit
import Darwin
import Foundation
import LadleKit
import Security

enum Bridge {
    static let outputLock = NSLock()

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

    static var appURL: URL? {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" { return bundle }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: BridgeIPC.appBundleIdentifier)
    }

    /// What the process at the socket must prove to be: the Ladle this helper lives in.
    static let appRequirement: SecRequirement? = appURL.flatMap {
        PeerVerification.requirement(forCodeAt: $0.appendingPathComponent("Contents/MacOS/Ladle"))
    }

    static let connectionLock = NSLock()
    static var connection: AppConnection?
    /// Request ids sent to the app and not answered yet, so a dropped connection can fail them.
    static let pending = Locked<Set<Int>>([])

    /// The open connection to Ladle, made (and checked) if needed. nil when Ladle isn't listening,
    /// or whatever listens isn't Ladle.
    static func currentConnection() -> AppConnection? {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        if let connection, connection.isOpen { return connection }
        connection = nil
        guard let fd = BridgeSocket.connect(path: BridgeIPC.socketPath()) else { return nil }
        guard let requirement = appRequirement, PeerVerification.verify(socket: fd, against: requirement) else {
            Darwin.close(fd)
            return nil
        }
        let opened = AppConnection(socket: fd)
        connection = opened
        opened.startReading()
        return opened
    }

    /// Starts Ladle in the background if needed and waits (up to 15 s) for it to listen.
    static func ensureApp() -> AppConnection? {
        if let connection = currentConnection() { return connection }
        guard let url = appURL else { return nil }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.arguments = [BridgeIPC.backgroundLaunchArgument]
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
        for _ in 0..<60 {
            usleep(250_000)
            if let connection = currentConnection() { return connection }
        }
        return nil
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
        if request.type == "hello" && currentConnection() == nil {
            var stored = storedSettings()
            stored?.token = ""
            reply(BridgeReply(replyTo: request.id, ok: true, settings: stored))
            return
        }
        guard let connection = ensureApp() else {
            reply(BridgeReply(replyTo: request.id, ok: false, error: "Ladle didn’t start"))
            return
        }
        let envelope = BridgeEnvelope(replyPort: nil, browser: browser.isEmpty ? nil : browser, request: request)
        guard let data = try? JSONEncoder().encode(envelope) else {
            reply(BridgeReply(replyTo: request.id, ok: false, error: "unreadable"))
            return
        }
        if let id = request.id { pending.withLock { _ = $0.insert(id) } }
        if !connection.send(NativeMessaging.frame(data)) {
            if let id = request.id { pending.withLock { _ = $0.remove(id) } }
            reply(BridgeReply(replyTo: request.id, ok: false, error: "Ladle didn’t answer"))
        }
    }

    // MARK: Messages from the app

    /// A frame from the app: the reply to one of our requests, or a push for the browser. Both go to
    /// the browser as they are; the extension tells them apart by `replyTo`.
    static func forward(_ frame: Data) {
        if let answer = try? JSONDecoder().decode(BridgeReply.self, from: frame), let id = answer.replyTo {
            pending.withLock { _ = $0.remove(id) }
        }
        write(frame)
    }

    /// The connection dropped: whatever was still waiting gets an answer.
    static func connectionClosed() {
        let waiting = pending.withLock { (ids: inout Set<Int>) -> Set<Int> in
            let copy = ids
            ids.removeAll()
            return copy
        }
        for id in waiting.sorted() {
            reply(BridgeReply(replyTo: id, ok: false, error: "Ladle didn’t answer"))
        }
    }
}

/// The helper's connection to the app. Only its reading thread closes the descriptor.
final class AppConnection {
    private let socket: Int32
    private let lock = NSLock()
    private var open = true

    init(socket: Int32) {
        self.socket = socket
    }

    var isOpen: Bool {
        lock.withLock { open }
    }

    func send(_ frame: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard open else { return false }
        if BridgeSocket.writeAll(socket, frame) { return true }
        open = false
        _ = Darwin.shutdown(socket, SHUT_RDWR)
        return false
    }

    func startReading() {
        let thread = Thread { [self] in
            BridgeSocket.readFrames(socket) { frame in Bridge.forward(frame) }
            lock.withLock { open = false }
            Darwin.close(socket)
            Bridge.connectionClosed()
        }
        thread.name = "Ladle connection"
        thread.start()
    }
}

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

dispatchMain()
