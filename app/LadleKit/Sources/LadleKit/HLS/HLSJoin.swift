import Foundation

/// How HLS segments become one file: fMP4 segments (with their init segment) join into
/// `.mp4` (`.m4a` for audio only); MPEG-TS segments are saved as `.ts`; packed audio keeps its type.
public enum HLSJoin {
    public static func container(for playlist: HLSMediaPlaylist) -> HLSInfo.Container {
        if playlist.map != nil { return .fragmentedMP4 }
        let ext = playlist.segments.first.map { FileNaming.fileExtension(of: $0.uri.path) } ?? ""
        switch ext {
        case "m4s", "mp4", "m4v", "m4a", "cmfv", "cmfa", "cmft": return .fragmentedMP4
        case "aac", "ac3", "ec3", "mp3": return .packedAudio
        default: return .transportStream
        }
    }

    /// The file extension the joined file gets.
    public static func fileExtension(container: HLSInfo.Container, audioOnly: Bool, segmentExtension: String = "aac") -> String {
        switch container {
        case .fragmentedMP4: return audioOnly ? "m4a" : "mp4"
        case .transportStream: return "ts"
        case .packedAudio: return ["aac", "ac3", "ec3", "mp3"].contains(segmentExtension) ? segmentExtension : "aac"
        }
    }

    /// Whether a variant's separate audio track can be merged into the video by the Mac's own tools.
    public static func canMergeSeparateAudio(video: HLSInfo.Container, audio: HLSInfo.Container) -> Bool {
        video == .fragmentedMP4 && audio == .fragmentedMP4
    }

    /// Rough size from bitrate and length, for "estimated size" in menus.
    public static func estimatedSize(bandwidth: Int, duration: Double) -> Int64? {
        guard bandwidth > 0, duration > 0 else { return nil }
        return Int64(Double(bandwidth) * duration / 8)
    }
}
