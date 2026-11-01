// Ladle's Safari extension: the same web extension as Chrome and Firefox (BrowserExtension/,
// copied in by the build), plus this handler. Safari has no native messaging host, so the
// extension's `browser.runtime.sendNativeMessage` calls arrive here instead.
//
// `hello` is answered from the settings Ladle leaves in its data folder. Downloads, page links
// and videos are written into Ladle's inbox folder (HandOffInbox) and Ladle itself, by path, is
// asked to open a `ladle://inbox?id=…` link naming the file: cookies never travel in a URL, and no
// other app that claims the ladle: scheme can receive them.

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
              var request = try? JSONDecoder().decode(BridgeRequest.self, from: data) else {
            completion(BridgeReply(replyTo: nil, ok: false, error: "unreadable"))
            return
        }
        if request.type == "hello" {
            var settings = Self.storedSettings()
            settings?.token = ""
            completion(BridgeReply(replyTo: request.id, ok: true, settings: settings))
            return
        }
        guard request.handOff(source: "Safari") != nil else {
            completion(BridgeReply(replyTo: request.id, ok: false, error: "unsupported"))
            return
        }
        request.browser = "Safari"
        let id: String
        do {
            // Ladle creates the folder on its first launch; the sandbox lets this extension write there.
            id = try HandOffInbox.drop(request, in: Self.paths.inbox)
        } catch {
            completion(BridgeReply(replyTo: request.id, ok: false, error: "Open Ladle once, then try again"))
            return
        }
        guard let link = HandOffInbox.link(id: id), let app = Self.containingApp else {
            completion(BridgeReply(replyTo: request.id, ok: false, error: "unsupported"))
            return
        }
        // Ladle's catch panel doesn't take focus, so Safari stays in front.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.open([link], withApplicationAt: app, configuration: configuration) { _, error in
            completion(BridgeReply(replyTo: request.id, ok: error == nil, error: error == nil ? nil : "Ladle didn’t open"))
        }
    }

    /// The real `~/Library/Application Support/Ladle`, not this extension's sandbox container.
    /// The entitlements allow reading it, and writing into its Inbox folder.
    static let paths: AppPaths = {
        var home = FileManager.default.homeDirectoryForCurrentUser
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            home = URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        return AppPaths(directory: home.appendingPathComponent("Library/Application Support/Ladle", isDirectory: true))
    }()

    static func storedSettings() -> BrowserSettingsSnapshot? {
        guard let data = try? Data(contentsOf: paths.browserSettings) else { return nil }
        return try? JSONDecoder().decode(BrowserSettingsSnapshot.self, from: data)
    }

    /// Ladle.app, three folders up from this extension (Contents/PlugIns/SafariExtension.appex).
    static var containingApp: URL? {
        let candidate = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if candidate.pathExtension == "app" { return candidate }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "me.alirazakhan.Ladle")
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
