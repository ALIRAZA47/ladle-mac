import Foundation

/// Names shared by the app and the native messaging helper (LadleBridge).
enum BridgeIPC {
    /// The app's local message port. The helper sends each browser message here.
    static let appPortName = "me.alirazakhan.Ladle.bridge"

    /// The helper's own port, for messages back to its browser.
    static func helperPortName(pid: Int32) -> String {
        "me.alirazakhan.Ladle.bridge.\(pid)"
    }

    static let appBundleIdentifier = "me.alirazakhan.Ladle"

    /// Passed when the helper launches the app, so it starts without opening its window.
    static let backgroundLaunchArgument = "--background"

    /// Message IDs on the port.
    static let requestMessageID: Int32 = 1
    static let pushMessageID: Int32 = 2
}
