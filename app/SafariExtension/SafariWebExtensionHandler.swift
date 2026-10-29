// Ladle's Safari extension: the same web extension as Chrome and Firefox (BrowserExtension/,
// copied in by the build), plus this handler. Safari has no native messaging host, so the
// extension's `browser.runtime.sendNativeMessage` calls arrive here instead.
//
// `hello` is answered from the settings Ladle leaves in its data folder. Downloads, page links
// and videos become a `ladle://add` link carrying Ladle's token, which macOS hands to Ladle.

import AppKit
import Foundation
import LadleKit
import SafariServices

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey]
        handle(message) { reply in
            let response = NSExtensionItem()
            response.userInfo = [SFExtensionMessageKey: Self.dictionary(reply)]
            context.completeRequest(returningItems: [response], completionHandler: nil)
        }
    }

    private func handle(_ message: Any?, completion: @escaping (BridgeReply) -> Void) {
        guard let message, JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message),
              let request = try? JSONDecoder().decode(BridgeRequest.self, from: data) else {
            completion(BridgeReply(replyTo: nil, ok: false, error: "unreadable"))
            return
        }
        let settings = Self.storedSettings()
        if request.type == "hello" {
            completion(BridgeReply(replyTo: request.id, ok: true, settings: settings))
            return
        }
        guard var handOff = request.handOff(source: "Safari") else {
            completion(BridgeReply(replyTo: request.id, ok: false, error: "unsupported"))
            return
        }
        handOff.token = settings?.token
        guard let link = LadleURL.make(handOff) else {
            completion(BridgeReply(replyTo: request.id, ok: false, error: "unsupported"))
            return
        }
        // Ladle's catch panel doesn't take focus, so Safari stays in front.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.open(link, configuration: configuration) { _, error in
            completion(BridgeReply(replyTo: request.id, ok: error == nil, error: error == nil ? nil : "Ladle didn’t open"))
        }
    }

    /// The real `~/Library/Application Support/Ladle`, not this extension's sandbox container.
    /// The entitlements allow reading it.
    static func storedSettings() -> BrowserSettingsSnapshot? {
        var home = FileManager.default.homeDirectoryForCurrentUser
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            home = URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        let paths = AppPaths(directory: home.appendingPathComponent("Library/Application Support/Ladle", isDirectory: true))
        guard let data = try? Data(contentsOf: paths.browserSettings) else { return nil }
        return try? JSONDecoder().decode(BrowserSettingsSnapshot.self, from: data)
    }

    /// The reply as a plain dictionary, the way Safari passes it back to JavaScript.
    static func dictionary(_ reply: BridgeReply) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(reply),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return ["ok": false]
        }
        return dictionary
    }
}
