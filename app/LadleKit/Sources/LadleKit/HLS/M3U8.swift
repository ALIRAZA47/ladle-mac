import Foundation

public struct HLSByteRange: Equatable, Sendable {
    public var length: Int64
    public var offset: Int64

    public init(length: Int64, offset: Int64) {
        self.length = length
        self.offset = offset
    }

    /// Inclusive end, as used in a `Range:` header.
    public var lastByte: Int64 { offset + length - 1 }
}

public struct HLSVariant: Equatable, Sendable {
    public var uri: URL
    public var bandwidth: Int
    public var averageBandwidth: Int?
    public var width: Int?
    public var height: Int?
    public var codecs: String?
    public var audioGroup: String?
    public var frameRate: Double?

    /// A variant without video: no resolution and only audio codecs (or none at all with an audio-ish URI).
    public var isAudioOnly: Bool {
        if width != nil || height != nil { return false }
        guard let codecs = codecs?.lowercased() else { return false }
        let list = codecs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let videoPrefixes = ["avc", "hvc", "hev", "dvh", "dva", "vp0", "vp9", "av01", "mp4v"]
        return !list.isEmpty && !list.contains(where: { codec in videoPrefixes.contains(where: { codec.hasPrefix($0) }) })
    }

    /// "2160p · 4K", "1080p", or a bitrate when the resolution isn't given.
    public var qualityLabel: String {
        if isAudioOnly { return "Audio only" }
        if let height {
            switch height {
            case 2160...: return "\(height)p · 4K"
            default: return "\(height)p"
            }
        }
        let mbps = Double(averageBandwidth ?? bandwidth) / 1_000_000
        return String(format: "%.1f Mbps", mbps)
    }
}

public struct HLSRendition: Equatable, Sendable {
    public var type: String
    public var groupID: String
    public var name: String
    public var language: String?
    public var isDefault: Bool
    public var uri: URL?
}

public struct HLSMasterPlaylist: Equatable, Sendable {
    public var variants: [HLSVariant]
    public var renditions: [HLSRendition]
    /// `EXT-X-SESSION-KEY` (or a stray `EXT-X-KEY`) with a method other than NONE.
    public var isProtected: Bool

    /// Video variants from best to worst, then audio-only ones.
    public var sortedVariants: [HLSVariant] {
        variants.sorted { a, b in
            if a.isAudioOnly != b.isAudioOnly { return !a.isAudioOnly }
            let ha = a.height ?? 0
            let hb = b.height ?? 0
            if ha != hb { return ha > hb }
            return (a.averageBandwidth ?? a.bandwidth) > (b.averageBandwidth ?? b.bandwidth)
        }
    }

    /// The separate audio playlist a variant needs, when its audio isn't muxed in.
    public func audioRendition(for variant: HLSVariant) -> HLSRendition? {
        guard let group = variant.audioGroup else { return nil }
        let candidates = renditions.filter { $0.type == "AUDIO" && $0.groupID == group && $0.uri != nil }
        return candidates.first(where: { $0.isDefault }) ?? candidates.first
    }

    /// Something to offer as "Audio only": an audio-only variant, or else a separate audio rendition.
    public var audioOnlyURL: URL? {
        if let variant = sortedVariants.first(where: { $0.isAudioOnly }) { return variant.uri }
        let audio = renditions.filter { $0.type == "AUDIO" && $0.uri != nil }
        return (audio.first(where: { $0.isDefault }) ?? audio.first)?.uri
    }
}

public struct HLSSegment: Equatable, Sendable {
    public var uri: URL
    public var duration: Double
    public var byteRange: HLSByteRange?
}

public struct HLSMap: Equatable, Sendable {
    public var uri: URL
    public var byteRange: HLSByteRange?
}

public struct HLSMediaPlaylist: Equatable, Sendable {
    public var segments: [HLSSegment]
    public var targetDuration: Double?
    public var map: HLSMap?
    /// Has `EXT-X-ENDLIST` or `PLAYLIST-TYPE:VOD`: a finished video, not a live stream.
    public var isComplete: Bool
    /// Any `EXT-X-KEY` whose method isn't NONE.
    public var isProtected: Bool

    public var totalDuration: Double { segments.reduce(0) { $0 + $1.duration } }
}

public enum HLSPlaylist: Equatable, Sendable {
    case master(HLSMasterPlaylist)
    case media(HLSMediaPlaylist)
}

public enum M3U8Error: Error, Equatable {
    case notAPlaylist
}

/// Parses HLS playlists (RFC 8216). Relative URIs resolve against `baseURL`.
public enum M3U8 {
    public static func parse(_ text: String, baseURL: URL) throws -> HLSPlaylist {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.first(where: { !$0.isEmpty }), first.hasPrefix("#EXTM3U") else {
            throw M3U8Error.notAPlaylist
        }
        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) {
            return .master(parseMaster(lines, baseURL: baseURL))
        }
        return .media(parseMedia(lines, baseURL: baseURL))
    }

    static func parseMaster(_ lines: [String], baseURL: URL) -> HLSMasterPlaylist {
        var variants: [HLSVariant] = []
        var renditions: [HLSRendition] = []
        var isProtected = false
        var pending: [String: String]?
        for line in lines {
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                let a = attributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
                renditions.append(HLSRendition(
                    type: (a["TYPE"] ?? "").uppercased(),
                    groupID: a["GROUP-ID"] ?? "",
                    name: a["NAME"] ?? "",
                    language: a["LANGUAGE"],
                    isDefault: (a["DEFAULT"] ?? "").uppercased() == "YES",
                    uri: a["URI"].flatMap { resolve($0, baseURL) }
                ))
            } else if line.hasPrefix("#EXT-X-SESSION-KEY:") || line.hasPrefix("#EXT-X-KEY:") {
                let a = attributes(String(line[line.index(after: line.firstIndex(of: ":")!)...]))
                if (a["METHOD"] ?? "NONE").uppercased() != "NONE" { isProtected = true }
            } else if line.hasPrefix("#") {
                continue
            } else if let a = pending {
                pending = nil
                guard let uri = resolve(line, baseURL) else { continue }
                var width: Int?
                var height: Int?
                if let res = a["RESOLUTION"] {
                    let parts = res.lowercased().split(separator: "x")
                    if parts.count == 2 {
                        width = Int(parts[0])
                        height = Int(parts[1])
                    }
                }
                variants.append(HLSVariant(
                    uri: uri,
                    bandwidth: Int(a["BANDWIDTH"] ?? "") ?? 0,
                    averageBandwidth: a["AVERAGE-BANDWIDTH"].flatMap { Int($0) },
                    width: width,
                    height: height,
                    codecs: a["CODECS"],
                    audioGroup: a["AUDIO"],
                    frameRate: a["FRAME-RATE"].flatMap { Double($0) }
                ))
            }
        }
        return HLSMasterPlaylist(variants: variants, renditions: renditions, isProtected: isProtected)
    }

    static func parseMedia(_ lines: [String], baseURL: URL) -> HLSMediaPlaylist {
        var segments: [HLSSegment] = []
        var targetDuration: Double?
        var map: HLSMap?
        var isComplete = false
        var isProtected = false
        var pendingDuration: Double?
        var pendingRange: HLSByteRange?
        var lastRangeEnd: [URL: Int64] = [:]
        var rangeSpec: (length: Int64, offset: Int64?)?
        for line in lines {
            if line.isEmpty { continue }
            if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count).split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                pendingDuration = Double(value.trimmingCharacters(in: .whitespaces)) ?? 0
            } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                targetDuration = Double(line.dropFirst("#EXT-X-TARGETDURATION:".count))
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                isComplete = true
            } else if line.hasPrefix("#EXT-X-PLAYLIST-TYPE:") {
                if line.dropFirst("#EXT-X-PLAYLIST-TYPE:".count).uppercased() == "VOD" { isComplete = true }
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let a = attributes(String(line.dropFirst("#EXT-X-KEY:".count)))
                if (a["METHOD"] ?? "NONE").uppercased() != "NONE" { isProtected = true }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                guard map == nil else { continue }
                let a = attributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                if let uri = a["URI"].flatMap({ resolve($0, baseURL) }) {
                    var range: HLSByteRange?
                    if let spec = a["BYTERANGE"].flatMap(parseRangeSpec), let offset = spec.offset {
                        range = HLSByteRange(length: spec.length, offset: offset)
                    }
                    map = HLSMap(uri: uri, byteRange: range)
                }
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                rangeSpec = parseRangeSpec(String(line.dropFirst("#EXT-X-BYTERANGE:".count)))
            } else if line.hasPrefix("#") {
                continue
            } else {
                guard let uri = resolve(line, baseURL) else {
                    pendingDuration = nil
                    rangeSpec = nil
                    continue
                }
                if let spec = rangeSpec {
                    let offset = spec.offset ?? lastRangeEnd[uri] ?? 0
                    pendingRange = HLSByteRange(length: spec.length, offset: offset)
                    lastRangeEnd[uri] = offset + spec.length
                }
                segments.append(HLSSegment(uri: uri, duration: pendingDuration ?? 0, byteRange: pendingRange))
                pendingDuration = nil
                pendingRange = nil
                rangeSpec = nil
            }
        }
        return HLSMediaPlaylist(segments: segments, targetDuration: targetDuration, map: map, isComplete: isComplete, isProtected: isProtected)
    }

    /// `n[@o]`
    static func parseRangeSpec(_ text: String) -> (length: Int64, offset: Int64?)? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "@")
        guard let first = parts.first, let length = Int64(first), length > 0 else { return nil }
        if parts.count > 1 {
            guard let offset = Int64(parts[1]) else { return nil }
            return (length, offset)
        }
        return (length, nil)
    }

    /// Splits an attribute list (`A=1,B="x,y",C=0x1F`) into a dictionary with quotes removed.
    public static func attributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var readingKey = true
        var inQuotes = false
        func commit() {
            let k = key.trimmingCharacters(in: .whitespaces).uppercased()
            if !k.isEmpty { result[k] = value.trimmingCharacters(in: .whitespaces) }
            key = ""
            value = ""
            readingKey = true
        }
        for ch in text {
            if readingKey {
                if ch == "=" { readingKey = false } else if ch == "," { commit() } else { key.append(ch) }
            } else {
                if ch == "\"" {
                    inQuotes.toggle()
                } else if ch == "," && !inQuotes {
                    commit()
                } else {
                    value.append(ch)
                }
            }
        }
        commit()
        return result
    }

    static func resolve(_ reference: String, _ base: URL) -> URL? {
        let trimmed = reference.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed, relativeTo: base)?.absoluteURL
    }
}
