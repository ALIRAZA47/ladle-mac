import AppKit
import AVFoundation
import Foundation
import LadleKit
import ServiceManagement

/// "Open Ladle at login" through the system's login items.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// Reads the clipboard only when it changed, and only while asked to (Ladle frontmost or its
/// menu bar window open). The text never leaves the Mac.
@MainActor
final class ClipboardWatcher {
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    var onLink: ((String) -> Void)?

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfActive() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func checkIfActive() {
        if NSApp.isActive { check() }
    }

    /// Checks now (Ladle became frontmost, or the menu bar window opened).
    func check(force: Bool = false) {
        let pasteboard = NSPasteboard.general
        guard force || pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        // Only plain text that looks like one link is read; anything else is ignored.
        guard pasteboard.availableType(from: [.string, .URL]) != nil else { return }
        if let text = pasteboard.string(forType: .string) {
            onLink?(text)
        } else if let url = NSURL(from: pasteboard) as URL? {
            onLink?(url.absoluteString)
        }
    }
}

/// Moves a replaced file to the Trash instead of deleting it.
struct TrashRecycler: FileRecycler {
    func recycle(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

/// Merges an HLS video and its separate audio track (both fragmented MP4) without re-encoding.
struct AVMuxer: MediaMuxer {
    func merge(video: URL, audio: URL, into output: URL) async throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        guard let sourceVideo = videoTracks.first, let sourceAudio = audioTracks.first else {
            throw DownloadFailure(.invalidResponse)
        }
        let duration = try await videoAsset.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        if let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try track.insertTimeRange(range, of: sourceVideo, at: .zero)
            track.preferredTransform = try await sourceVideo.load(.preferredTransform)
        }
        let audioDuration = try await audioAsset.load(.duration)
        if let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let audioRange = CMTimeRange(start: .zero, duration: CMTimeMinimum(duration, audioDuration))
            try track.insertTimeRange(audioRange, of: sourceAudio, at: .zero)
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw DownloadFailure(.writeFailed)
        }
        try? FileManager.default.removeItem(at: output)
        export.outputURL = output
        export.outputFileType = .mp4
        await export.export()
        if export.status != .completed {
            throw export.error ?? DownloadFailure(.writeFailed)
        }
    }
}
