import CoreFoundation
import Foundation
import LadleKit

/// The app's end of the native messaging helper: a local CFMessagePort. The helper (LadleBridge)
/// sends one message per browser request and gets the reply synchronously; the app reaches the
/// helper's own port for pushes ("Let the browser handle it", settings changes).
final class BridgeServer {
    private var port: CFMessagePort?
    private var source: CFRunLoopSource?

    /// Answers a helper request. Called on the main thread.
    var handler: ((BridgeEnvelope) -> BridgeReply)?

    @discardableResult
    func start() -> Bool {
        guard port == nil else { return true }
        var context = CFMessagePortContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        var shouldFree: DarwinBoolean = false
        let callback: CFMessagePortCallBack = { _, _, data, info in
            guard let info, let data else { return nil }
            let server = Unmanaged<BridgeServer>.fromOpaque(info).takeUnretainedValue()
            guard let reply = server.respond(to: data as Data) else { return nil }
            return Unmanaged.passRetained(reply as CFData)
        }
        guard let created = CFMessagePortCreateLocal(nil, BridgeIPC.appPortName as CFString, callback, &context, &shouldFree) else {
            return false
        }
        port = created
        if let runLoopSource = CFMessagePortCreateRunLoopSource(nil, created, 0) {
            source = runLoopSource
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, CFRunLoopMode.commonModes)
        }
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes) }
        if let port { CFMessagePortInvalidate(port) }
        source = nil
        port = nil
    }

    private func respond(to data: Data) -> Data? {
        guard let envelope = try? JSONDecoder().decode(BridgeEnvelope.self, from: data) else {
            return try? NativeMessaging.encode(BridgeReply(replyTo: nil, ok: false, error: "unreadable"))
        }
        let reply = handler?(envelope) ?? BridgeReply(replyTo: envelope.request.id, ok: false, error: "starting")
        return try? NativeMessaging.encode(reply)
    }

    /// Sends a message to a helper, which passes it on to its browser.
    @discardableResult
    static func push(_ message: BridgePush, to portName: String) -> Bool {
        guard let remote = CFMessagePortCreateRemote(nil, portName as CFString),
              let data = try? NativeMessaging.encode(message) else { return false }
        let status = CFMessagePortSendRequest(remote, BridgeIPC.pushMessageID, data as CFData, 2, 0, nil, nil)
        CFMessagePortInvalidate(remote)
        return status == kCFMessagePortSuccess
    }
}
