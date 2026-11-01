import Darwin
import Foundation
import Security

/// Who is at the other end of a local socket, and whether it's a particular piece of Ladle's own
/// code. A Unix socket tells us the peer's process id and user; the Security framework then checks
/// that process against the designated requirement of the binary we expect: for an ad-hoc signed
/// build, its cdhashes; for a Developer ID build, its identifier and team. Nothing a message says
/// about itself is trusted, only what the kernel and the code signature say.
enum PeerVerification {
    /// The designated requirement of the signed code at `url`, or nil when it isn't signed.
    static func requirement(forCodeAt url: URL) -> SecRequirement? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, SecCSFlags(), &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    /// `SOL_LOCAL` and `LOCAL_PEERPID` from <sys/un.h>, spelled out: the peer's process id for a Unix socket.
    private static let socketLevelLocal: Int32 = 0
    private static let optionPeerPID: Int32 = 0x002

    /// The process at the far end of `socket`, and the user it runs as.
    static func peer(of socket: Int32) -> (pid: pid_t, uid: uid_t)? {
        var pid: pid_t = 0
        var pidSize = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(socket, socketLevelLocal, optionPeerPID, &pid, &pidSize) == 0, pid > 0 else { return nil }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(socket, &uid, &gid) == 0 else { return nil }
        return (pid, uid)
    }

    /// Whether the process at the far end of `socket` runs as this user, is validly signed and
    /// satisfies `requirement`.
    static func verify(socket: Int32, against requirement: SecRequirement) -> Bool {
        guard let peer = peer(of: socket), peer.uid == getuid() else { return false }
        var code: SecCode?
        let attributes: [CFString: Any] = [kSecGuestAttributePid: Int(peer.pid)]
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, SecCSFlags(), &code) == errSecSuccess,
              let code else { return false }
        return SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess
    }
}
