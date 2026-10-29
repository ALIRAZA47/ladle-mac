import Foundation

/// File names: deriving them from links and headers, cleaning them, and avoiding clashes.
public enum FileNaming {
    public static let partSuffix = ".ladle-part"

    /// Endings that belong together, so "a.tar.gz" becomes "a 2.tar.gz", not "a.tar 2.gz".
    static let compoundExtensions = ["tar.gz", "tar.bz2", "tar.xz", "tar.zst"]

    /// Lowercased extension without the dot, or "" when there is none.
    public static func fileExtension(of name: String) -> String {
        let base = (name as NSString).lastPathComponent
        guard let dot = base.lastIndex(of: "."), dot != base.startIndex else { return "" }
        let ext = base[base.index(after: dot)...]
        guard !ext.isEmpty, ext.count <= 10, !ext.contains(" ") else { return "" }
        return ext.lowercased()
    }

    /// Splits "archive.tar.gz" into ("archive", ".tar.gz") and "photo.JPG" into ("photo", ".JPG").
    public static func splitExtension(_ name: String) -> (stem: String, ext: String) {
        let lower = name.lowercased()
        for compound in compoundExtensions where lower.hasSuffix("." + compound) && lower.count > compound.count + 1 {
            let cut = name.index(name.endIndex, offsetBy: -(compound.count + 1))
            return (String(name[..<cut]), String(name[cut...]))
        }
        let ext = fileExtension(of: name)
        guard !ext.isEmpty else { return (name, "") }
        let cut = name.index(name.endIndex, offsetBy: -(ext.count + 1))
        return (String(name[..<cut]), String(name[cut...]))
    }

    /// Makes a string safe as a single file name on macOS.
    public static func sanitize(_ raw: String, fallback: String = "download") -> String {
        var name = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        name = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = fallback }
        // Leave room for " 99" and ".ladle-part" inside the 255-byte limit.
        let limit = 200
        if name.utf8.count > limit {
            let (stem, ext) = splitExtension(name)
            var shortStem = stem
            while (shortStem + ext).utf8.count > limit, !shortStem.isEmpty { shortStem.removeLast() }
            name = shortStem.isEmpty ? String(name.prefix(limit)) : shortStem + ext
        }
        return name
    }

    /// The last path component of the link, percent-decoded, or nil when the path is empty.
    public static func nameFromURL(_ url: URL) -> String? {
        let component = url.lastPathComponent
        guard !component.isEmpty, component != "/" else { return nil }
        let decoded = component.removingPercentEncoding ?? component
        let cleaned = sanitize(decoded, fallback: "")
        return cleaned.isEmpty ? nil : cleaned
    }

    /// File name from a `Content-Disposition` header. Prefers RFC 5987 `filename*=`.
    public static func nameFromContentDisposition(_ header: String) -> String? {
        let parts = splitParameters(header)
        var plain: String?
        var extended: String?
        for part in parts {
            guard let eq = part.firstIndex(of: "=") else { continue }
            let key = part[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if key == "filename*" {
                // charset'language'percent-encoded
                let pieces = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                if pieces.count == 3 {
                    let encoded = String(pieces[2]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    extended = encoded.removingPercentEncoding ?? encoded
                }
            } else if key == "filename" {
                if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                    value = value.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
                }
                plain = value
            }
        }
        guard let chosen = extended ?? plain else { return nil }
        // Some servers send a full path; keep only the last part.
        let lastPart = chosen.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? chosen
        let cleaned = sanitize(lastPart, fallback: "")
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Splits `a; b="x;y"; c` on semicolons outside quotes.
    private static func splitParameters(_ header: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for ch in header {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" && inQuotes {
                current.append(ch)
                escaped = true
                continue
            }
            if ch == "\"" { inQuotes.toggle() }
            if ch == ";" && !inQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        result.append(current)
        return result.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Extension for a MIME type, for links like `download.php?id=3` that don't name the file.
    public static func fileExtension(forMIMEType mime: String) -> String? {
        let type = mime.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        let map: [String: String] = [
            "application/pdf": "pdf",
            "application/zip": "zip",
            "application/x-zip-compressed": "zip",
            "application/x-apple-diskimage": "dmg",
            "application/x-iso9660-image": "iso",
            "application/x-7z-compressed": "7z",
            "application/vnd.rar": "rar",
            "application/x-rar-compressed": "rar",
            "application/gzip": "gz",
            "application/x-gzip": "gz",
            "application/x-tar": "tar",
            "application/x-xz": "xz",
            "application/x-bzip2": "bz2",
            "application/epub+zip": "epub",
            "application/msword": "doc",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
            "text/csv": "csv",
            "text/plain": "txt",
            "video/mp4": "mp4",
            "video/quicktime": "mov",
            "video/x-matroska": "mkv",
            "video/webm": "webm",
            "video/x-msvideo": "avi",
            "video/mp2t": "ts",
            "audio/mpeg": "mp3",
            "audio/flac": "flac",
            "audio/x-flac": "flac",
            "audio/wav": "wav",
            "audio/x-wav": "wav",
            "audio/mp4": "m4a",
            "audio/x-m4a": "m4a",
            "audio/aac": "aac",
            "audio/ogg": "ogg",
            "image/png": "png",
            "image/jpeg": "jpg",
            "image/heic": "heic",
            "image/webp": "webp",
            "image/gif": "gif",
            "image/svg+xml": "svg",
            "image/tiff": "tiff",
        ]
        return map[type]
    }

    /// The best name for a download: header, then link, then host. Adds an extension from the MIME type if missing.
    public static func suggestedName(url: URL, contentDisposition: String? = nil, mimeType: String? = nil) -> String {
        var name = contentDisposition.flatMap(nameFromContentDisposition) ?? nameFromURL(url) ?? sanitize(url.host ?? "download")
        if fileExtension(of: name).isEmpty, let mime = mimeType, let ext = fileExtension(forMIMEType: mime) {
            name += "." + ext
        }
        return name
    }

    /// "name.ext", "name 2.ext", "name 3.ext"… until `isTaken` says no.
    public static func availableName(for name: String, isTaken: (String) -> Bool) -> String {
        guard isTaken(name) else { return name }
        let (stem, ext) = splitExtension(name)
        var n = 2
        while n < 10_000 {
            let candidate = "\(stem) \(n)\(ext)"
            if !isTaken(candidate) { return candidate }
            n += 1
        }
        return "\(stem) \(UUID().uuidString.prefix(8))\(ext)"
    }

    /// Lowercase, no dots, no blanks, no duplicates, original order.
    public static func normalizedExtensions(_ list: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in list {
            var ext = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            while ext.hasPrefix(".") { ext.removeFirst() }
            guard !ext.isEmpty, ext.count <= 10, ext.allSatisfy({ $0.isLetter || $0.isNumber }) else { continue }
            if seen.insert(ext).inserted { result.append(ext) }
        }
        return result
    }
}
