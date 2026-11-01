import Darwin
import Foundation
import LadleKit

/// Names shared by the app and the native messaging helper (LadleBridge).
enum BridgeIPC {
    /// The app listens on a Unix socket in its data folder. The helper connects to it once per
    /// browser session, sends each browser message as a frame and reads replies and pushes back on
    /// the same connection. Both ends check who is at the other end (PeerVerification).
    static let socketFileName = "bridge.sock"

    /// Where the socket is. A `sockaddr_un` path holds about a hundred bytes, so with a very long
    /// home folder it moves to the user's private temporary folder instead.
    static func socketPath(paths: AppPaths = .standard()) -> String {
        let preferred = paths.directory.appendingPathComponent(socketFileName).path
        if preferred.utf8.count < 100 { return preferred }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        if length > 0, length <= buffer.count {
            return (String(cString: buffer) as NSString).appendingPathComponent("me.alirazakhan.Ladle.sock")
        }
        return preferred
    }

    static let appBundleIdentifier = "me.alirazakhan.Ladle"

    /// Passed when the helper launches the app, so it starts without opening its window.
    static let backgroundLaunchArgument = "--background"
}

/// The socket plumbing both ends share. Frames use the native messaging framing (a 32-bit length,
/// then JSON), the same as between the browser and the helper.
enum BridgeSocket {
    /// Puts `path` into `address`. False when it doesn't fit.
    static func fill(_ address: inout sockaddr_un, path: String) -> Bool {
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { return false }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { chars in
                _ = strncpy(chars, path, capacity)
            }
        }
        return true
    }

    /// A connected stream socket to whatever listens at `path`, or nil when nothing does.
    static func connect(path: String) -> Int32? {
        var address = sockaddr_un()
        guard fill(&address, path: path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            return nil
        }
        quietPipes(fd)
        return fd
    }

    /// A write to a peer that went away fails instead of killing the process.
    static func quietPipes(_ fd: Int32) {
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Writes all of `data`. False when the peer is gone.
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return true }
            while offset < raw.count {
                let written = Darwin.write(fd, base + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }

    /// Reads frames until the peer closes or sends something unreadable, handing each one to `handle`.
    /// Returns when the connection is over; the caller closes the descriptor.
    static func readFrames(_ fd: Int32, handle: (Data) -> Void) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { return }
            buffer.append(chunk, count: count)
            guard let frames = try? NativeMessaging.takeFrames(from: &buffer) else { return }
            for frame in frames { handle(frame) }
        }
    }
}
