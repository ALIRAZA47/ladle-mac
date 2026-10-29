import Foundation

/// The rules for "Link on your clipboard": a single http(s) link whose file has an extension Ladle
/// knows, that isn't already in the list and wasn't dismissed. Clipboard text never leaves the Mac.
public struct ClipboardDetector: Sendable {
    public var knownExtensions: Set<String>

    public init(knownExtensions: Set<String> = FileCategory.knownExtensions) {
        self.knownExtensions = knownExtensions
    }

    /// The link to offer, or nil.
    /// - Parameters:
    ///   - text: the clipboard's plain text.
    ///   - existing: links already in the download list.
    ///   - dismissed: links the person answered "Not now" to.
    public func candidate(in text: String?, existing: Set<String> = [], dismissed: Set<String> = []) -> URL? {
        guard let text, text.utf8.count <= 4096 else { return nil }
        guard let url = LinkParser.link(from: text) else { return nil }
        let key = url.absoluteString
        guard !existing.contains(key), !dismissed.contains(key) else { return nil }
        guard let name = FileNaming.nameFromURL(url) else { return nil }
        let ext = FileNaming.fileExtension(of: name)
        guard !ext.isEmpty, knownExtensions.contains(ext) else { return nil }
        return url
    }
}
