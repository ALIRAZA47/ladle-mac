import Foundation

/// Every web address the app opens. They must match SPEC.md ("URLs" and "Docs pages the app links to").
enum LadleLinks {
    static let website = URL(string: "https://ladle.alirazakhan.me/")!
    static let download = URL(string: "https://ladle.alirazakhan.me/download/")!
    static let changelog = URL(string: "https://ladle.alirazakhan.me/changelog/")!
    static let docsHome = URL(string: "https://ladle.alirazakhan.me/docs/")!
    static let privacy = URL(string: "https://ladle.alirazakhan.me/privacy/")!
    static let support = URL(string: "https://github.com/ALIRAZA47/ladle-mac/issues")!

    static func docs(_ path: String, anchor: String? = nil) -> URL {
        var string = "https://ladle.alirazakhan.me/docs/" + path
        if !string.hasSuffix("/") { string += "/" }
        if let anchor { string += "#" + anchor }
        return URL(string: string)!
    }

    static let install = docs("getting-started/install")
    static let setUpBrowser = docs("getting-started/set-up-your-browser")
    static let setUpSafari = docs("getting-started/set-up-your-browser", anchor: "safari")
    static let setUpChrome = docs("getting-started/set-up-your-browser", anchor: "chrome")
    static let setUpFirefox = docs("getting-started/set-up-your-browser", anchor: "firefox")
    static let firstDownload = docs("getting-started/first-download")
    static let menuBarDockAndNotifications = docs("getting-started/menu-bar-dock-and-notifications")
    static let pasteDropOrShortcut = docs("adding-downloads/paste-drop-or-shortcut")
    static let manyLinks = docs("adding-downloads/many-links")
    static let videoButton = docs("adding-downloads/video-button")
    static let mainQueue = docs("queues-and-speed/main-queue")
    static let tonightQueue = docs("queues-and-speed/tonight-queue")
    static let connectionsAndSpeed = docs("queues-and-speed/connections-and-speed-limits")
    static let categoriesAndFolders = docs("files-and-folders/categories-and-folders")
    static let duplicateNames = docs("files-and-folders/duplicate-file-names")
    static let checksums = docs("files-and-folders/checksums")
    static let downloadFailed = docs("fixing-problems/download-failed")
    static let wontResume = docs("fixing-problems/wont-resume")
    static let browserNotHandingOff = docs("fixing-problems/browser-not-handing-off")
    static let updates = docs("updates")
    static let keyboardShortcuts = docs("reference/keyboard-shortcuts")
    static let settingsReference = docs("reference/settings")

    /// Release notes for a version: `#v1-0-0`.
    static func releaseNotes(version: String) -> URL {
        URL(string: "https://ladle.alirazakhan.me/changelog/#v" + version.replacingOccurrences(of: ".", with: "-"))!
    }
}
