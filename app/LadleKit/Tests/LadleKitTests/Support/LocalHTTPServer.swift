#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
@testable import LadleKit

/// A tiny HTTP/1.1 server on 127.0.0.1 for transport tests: serves byte ranges, redirects,
/// and records the headers it receives. One request per connection.
final class LocalHTTPServer: @unchecked Sendable {
    struct Route {
        var body: Data
        var redirect: String?
        var supportsRanges = true
    }

    private var listener: Int32 = -1
    private(set) var port: UInt16 = 0
    private let routes = Locked<[String: Route]>([:])
    let received = Locked<[(path: String, headers: [String: String])]>([])
    private let running = Locked(true)

    init() throws {
        #if canImport(Darwin)
        let stream = SOCK_STREAM
        #else
        let stream = Int32(SOCK_STREAM.rawValue)
        #endif
        listener = socket(AF_INET, stream, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 64) == 0 else { throw POSIXError(.EADDRINUSE) }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        port = UInt16(bigEndian: actual.sin_port)
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.start()
    }

    func route(_ path: String, _ route: Route) {
        routes.withLock { $0[path] = route }
    }

    func url(_ path: String, host: String = "127.0.0.1") -> URL {
        URL(string: "http://\(host):\(port)\(path)")!
    }

    func stop() {
        running.withLock { $0 = false }
        shutdown(listener, Int32(SHUT_RDWR))
        close(listener)
    }

    private func acceptLoop() {
        while running.current {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if !running.current { return }
                continue
            }
            #if canImport(Darwin)
            var yes: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            #endif
            let thread = Thread { [weak self] in
                self?.handle(client)
                close(client)
            }
            thread.start()
        }
    }

    private func readRequest(_ fd: Int32) -> (String, [String: String])? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !data.contains(Data("\r\n\r\n".utf8)) {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { return nil }
            data.append(buffer, count: n)
            if data.count > 65536 { return nil }
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where line.contains(":") {
            let colon = line.firstIndex(of: ":")!
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return (String(parts[1]), headers)
    }

    private func send(_ fd: Int32, _ data: Data) -> Bool {
        var offset = 0
        while offset < data.count {
            #if canImport(Darwin)
            let flags: Int32 = 0
            #else
            let flags = Int32(MSG_NOSIGNAL)
            #endif
            let n = data.withUnsafeBytes { raw in
                Glue.send(fd, raw.baseAddress! + offset, min(64 * 1024, data.count - offset), flags)
            }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }

    private func handle(_ fd: Int32) {
        guard let (path, headers) = readRequest(fd) else { return }
        received.withLock { $0.append((path, headers)) }
        guard let route = routes.withLock({ $0[path] }) else {
            _ = send(fd, Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        if let target = route.redirect {
            _ = send(fd, Data("HTTP/1.1 302 Found\r\nLocation: \(target)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        let total = route.body.count
        var start = 0
        var end = total - 1
        var status = "200 OK"
        var extra = ""
        if route.supportsRanges, let range = headers["range"], range.hasPrefix("bytes=") {
            let spec = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            start = Int(spec[0]) ?? 0
            if spec.count > 1, let e = Int(spec[1]) { end = min(e, total - 1) }
            status = "206 Partial Content"
            extra = "Content-Range: bytes \(start)-\(end)/\(total)\r\n"
        }
        let head = "HTTP/1.1 \(status)\r\nContent-Length: \(end - start + 1)\r\n\(extra)ETag: \"local\"\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n"
        guard send(fd, Data(head.utf8)) else { return }
        _ = send(fd, route.body.subdata(in: start..<(end + 1)))
    }
}

/// Disambiguates the C `send` from the method above.
private enum Glue {
    static func send(_ fd: Int32, _ pointer: UnsafeRawPointer, _ count: Int, _ flags: Int32) -> Int {
        #if canImport(Darwin)
        return Darwin.send(fd, pointer, count, flags)
        #else
        return Glibc.send(fd, pointer, count, flags)
        #endif
    }
}
