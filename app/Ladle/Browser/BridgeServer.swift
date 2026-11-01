import Darwin
import Foundation
import LadleKit
import Security

/// The app's end of the native messaging helper: a Unix socket in Ladle's data folder. Each helper
/// (one per browser) keeps one connection and sends a request per browser message; the reply and any
/// pushes ("Let the browser handle it", new settings) go back on the same connection.
///
/// A connection is trusted only when the process behind it is Ladle's own LadleBridge, checked with
/// PeerVerification against the helper's designated requirement. Anything else that connects gets its
/// hand-offs treated like a web page's links: no cookies, and always a question first.
final class BridgeServer {
    /// Answers a helper request. Called on the main thread.
    var handler: ((_ envelope: BridgeEnvelope, _ connection: Int, _ trusted: Bool) -> BridgeReply)?

    private let lock = NSLock()
    private var listener: Int32 = -1
    private var path: String?
    private var requirement: SecRequirement?
    private var connections: [Int: Connection] = [:]
    private var nextID = 1

    /// Starts listening. `helperURL` is the LadleBridge binary a peer must prove to be.
    @discardableResult
    func start(path: String = BridgeIPC.socketPath(), helperURL: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard listener < 0 else { return true }
        // Another copy of Ladle may be serving already; leave its socket alone.
        if let other = BridgeSocket.connect(path: path) {
            Darwin.close(other)
            return false
        }
        var address = sockaddr_un()
        guard BridgeSocket.fill(&address, path: path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        unlink(path)
        // The socket file is this user's only.
        let previousMask = umask(0o077)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previousMask)
        guard bound == 0, listen(fd, 16) == 0 else {
            Darwin.close(fd)
            unlink(path)
            return false
        }
        listener = fd
        self.path = path
        requirement = PeerVerification.requirement(forCodeAt: helperURL)
        let thread = Thread { [weak self] in self?.acceptLoop(listener: fd) }
        thread.name = "Ladle bridge"
        thread.start()
        return true
    }

    func stop() {
        let (fd, path, open) = lock.withLock { () -> (Int32, String?, [Connection]) in
            let result = (listener, self.path, Array(connections.values))
            listener = -1
            self.path = nil
            connections.removeAll()
            return result
        }
        // shutdown wakes the accept and read calls; the threads close the descriptors themselves.
        if fd >= 0 { _ = Darwin.shutdown(fd, SHUT_RDWR) }
        if let path { unlink(path) }
        for connection in open { connection.hangUp() }
    }

    /// Sends a message to one helper. False when that connection is gone.
    @discardableResult
    func push(_ message: BridgePush, to connectionID: Int) -> Bool {
        guard let connection = lock.withLock({ connections[connectionID] }),
              let data = try? NativeMessaging.encode(message) else { return false }
        return connection.write(NativeMessaging.frame(data))
    }

    /// Sends a message to every verified helper.
    func broadcast(_ message: BridgePush) {
        guard let data = try? NativeMessaging.encode(message) else { return }
        let targets = lock.withLock { connections.values.filter(\.trusted) }
        for connection in targets { connection.write(NativeMessaging.frame(data)) }
    }

    // MARK: Connections

    private func acceptLoop(listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            BridgeSocket.quietPipes(client)
            let requirement = lock.withLock { self.requirement }
            let trusted = requirement.map { PeerVerification.verify(socket: client, against: $0) } ?? false
            let connection: Connection = lock.withLock {
                let id = nextID
                nextID += 1
                let connection = Connection(id: id, socket: client, trusted: trusted)
                connections[id] = connection
                return connection
            }
            let thread = Thread { [weak self] in self?.serve(connection) }
            thread.name = "Ladle bridge connection \(connection.id)"
            thread.start()
        }
        Darwin.close(listener)
    }

    private func serve(_ connection: Connection) {
        BridgeSocket.readFrames(connection.socket) { frame in
            let reply = answer(frame, connection: connection)
            if let data = try? NativeMessaging.encode(reply) {
                connection.write(NativeMessaging.frame(data))
            }
        }
        lock.withLock { connections[connection.id] = nil }
        connection.finish()
    }

    private func answer(_ frame: Data, connection: Connection) -> BridgeReply {
        guard let envelope = try? JSONDecoder().decode(BridgeEnvelope.self, from: frame) else {
            return BridgeReply(replyTo: nil, ok: false, error: "unreadable")
        }
        let starting = BridgeReply(replyTo: envelope.request.id, ok: false, error: "starting")
        if Thread.isMainThread {
            return handler?(envelope, connection.id, connection.trusted) ?? starting
        }
        return DispatchQueue.main.sync {
            handler?(envelope, connection.id, connection.trusted) ?? starting
        }
    }

    /// One helper's connection. Only its reading thread closes the descriptor, so a descriptor number
    /// is never reused under a read in flight.
    private final class Connection {
        let id: Int
        let socket: Int32
        let trusted: Bool
        private let lock = NSLock()
        private var open = true

        init(id: Int, socket: Int32, trusted: Bool) {
            self.id = id
            self.socket = socket
            self.trusted = trusted
        }

        @discardableResult
        func write(_ data: Data) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard open else { return false }
            if BridgeSocket.writeAll(socket, data) { return true }
            open = false
            _ = Darwin.shutdown(socket, SHUT_RDWR)
            return false
        }

        /// Ends the conversation; the reading thread then finishes.
        func hangUp() {
            lock.lock()
            defer { lock.unlock() }
            guard open else { return }
            open = false
            _ = Darwin.shutdown(socket, SHUT_RDWR)
        }

        /// Called once by the reading thread when it's done.
        func finish() {
            hangUp()
            Darwin.close(socket)
        }
    }
}
