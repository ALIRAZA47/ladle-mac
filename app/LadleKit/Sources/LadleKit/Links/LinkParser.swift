import Foundation

/// One link found in pasted text, with an optional checksum written after it.
public struct ParsedLink: Equatable, Sendable {
    public var url: URL
    public var checksum: ExpectedChecksum?

    public init(url: URL, checksum: ExpectedChecksum? = nil) {
        self.url = url
        self.checksum = checksum
    }
}

/// Turns typed or pasted text into download links.
public enum LinkParser {
    /// Hard cap on what one numbered series may expand to.
    public static let maxSeriesExpansion = 1000

    /// A single http(s) link with a host, or nil. Leading/trailing blanks and `<…>` are ignored.
    public static func link(from text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("<"), s.hasSuffix(">") { s = String(s.dropFirst().dropLast()) }
        guard !s.isEmpty, !s.contains(where: { $0.isWhitespace }) else { return nil }
        let lower = s.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
        guard let url = URL(string: s) ?? URL(string: s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(.urlQueryAllowed).union(CharacterSet(charactersIn: "#%"))) ?? s) else {
            return nil
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// Expands the first `[a-b]` numeric range in `text`, then the rest, recursively.
    /// `ep-[01-12].mp3` keeps the zero padding; `img[1-20].jpg` doesn't add any.
    public static func expandSeries(_ text: String, limit: Int = maxSeriesExpansion) -> [String] {
        guard let match = firstRange(in: text) else { return [text] }
        let prefix = String(text[..<match.range.lowerBound])
        let suffix = String(text[match.range.upperBound...])
        let step = match.from <= match.to ? 1 : -1
        let count = abs(match.to - match.from) + 1
        guard count <= limit else { return [text] }
        var results: [String] = []
        var n = match.from
        for _ in 0..<count {
            var number = String(n)
            if number.count < match.width { number = String(repeating: "0", count: match.width - number.count) + number }
            for tail in expandSeries(suffix, limit: limit) {
                results.append(prefix + number + tail)
                if results.count >= limit { return results }
            }
            n += step
        }
        return results
    }

    private struct SeriesRange {
        var range: Range<String.Index>
        var from: Int
        var to: Int
        var width: Int
    }

    private static func firstRange(in text: String) -> SeriesRange? {
        var searchStart = text.startIndex
        while let open = text[searchStart...].firstIndex(of: "[") {
            guard let close = text[open...].firstIndex(of: "]") else { return nil }
            let inner = text[text.index(after: open)..<close]
            let bounds = inner.split(separator: "-", omittingEmptySubsequences: false)
            if bounds.count == 2,
               let a = bounds.first, let b = bounds.last,
               !a.isEmpty, !b.isEmpty, a.count <= 9, b.count <= 9,
               a.allSatisfy({ $0.isASCII && $0.isNumber }), b.allSatisfy({ $0.isASCII && $0.isNumber }),
               let from = Int(a), let to = Int(b) {
                let padded = (a.count > 1 && a.hasPrefix("0")) || (b.count > 1 && b.hasPrefix("0"))
                let width = padded ? max(a.count, b.count) : 0
                return SeriesRange(range: open..<text.index(after: close), from: from, to: to, width: width)
            }
            searchStart = text.index(after: open)
        }
        return nil
    }

    /// Whether the text holds a `[a-b]` series.
    public static func containsSeries(_ text: String) -> Bool {
        firstRange(in: text) != nil
    }

    /// Every link in pasted text, one per line (blank-separated also works), series expanded,
    /// duplicates removed. A SHA-256 or MD5 right after a link is kept as its checksum.
    public static func parseBatch(_ text: String) -> [ParsedLink] {
        var results: [ParsedLink] = []
        var seen = Set<String>()
        for line in text.components(separatedBy: .newlines) {
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            var index = 0
            while index < tokens.count {
                let token = tokens[index]
                index += 1
                let candidates = expandSeries(token)
                let links = candidates.compactMap(link(from:))
                guard !links.isEmpty else { continue }
                var checksum: ExpectedChecksum?
                if index < tokens.count, let sum = ExpectedChecksum.parse(tokens[index], source: .pasted) {
                    checksum = sum
                    index += 1
                }
                for url in links where seen.insert(url.absoluteString).inserted {
                    // A checksum after a series can't belong to every file in it.
                    results.append(ParsedLink(url: url, checksum: links.count == 1 ? checksum : nil))
                }
            }
        }
        return results
    }
}
