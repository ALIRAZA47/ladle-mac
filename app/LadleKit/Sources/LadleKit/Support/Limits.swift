import Foundation

/// Bounds on numbers that come from servers and playlists. Swift traps on integer overflow, so every
/// size, offset and duration a server sends is checked against these before any arithmetic uses it.
public enum Limits {
    /// The biggest size Ladle accepts from `Content-Length`, `Content-Range` or an HLS byte range: 1 PiB.
    /// Anything larger is treated as "unknown" or refused; no real download comes close.
    public static let maxFileSize: Int64 = 1 << 50

    /// The longest segment or playlist duration accepted, in seconds (about eleven days).
    public static let maxDuration: Double = 1_000_000

    /// Segments in one HLS download, video and audio together (a 10-hour stream at 2 s each is 18 000).
    public static let maxSegments = 100_000
}
