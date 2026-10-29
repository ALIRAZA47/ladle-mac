import Foundation
import LadleKit

/// Publishes an NSProgress for each running download's part file, so Finder draws a progress
/// bar on it. Cancelling from Finder pauses the download.
@MainActor
final class FinderProgressController {
    private var published: [UUID: Progress] = [:]
    /// Called when someone cancels the download from Finder.
    var onPause: ((UUID) -> Void)?

    func sync(_ items: [DownloadItem]) {
        var running = Set<UUID>()
        for item in items where item.status == .downloading && item.kind == .file {
            guard let total = item.totalBytes, total > 0,
                  FileManager.default.fileExists(atPath: item.partURL.path) else { continue }
            running.insert(item.id)
            let progress: Progress
            if let existing = published[item.id], existing.fileURL == item.partURL {
                progress = existing
            } else {
                published[item.id]?.unpublish()
                progress = Progress(totalUnitCount: total)
                progress.kind = .file
                progress.fileOperationKind = .downloading
                progress.fileURL = item.partURL
                progress.isCancellable = true
                progress.isPausable = false
                let id = item.id
                progress.cancellationHandler = { [weak self] in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.onPause?(id) }
                    }
                }
                progress.publish()
                published[item.id] = progress
            }
            progress.totalUnitCount = total
            progress.completedUnitCount = min(total, item.receivedBytes)
        }
        for (id, progress) in published where !running.contains(id) {
            progress.unpublish()
            published[id] = nil
        }
    }

    func stopAll() {
        for progress in published.values { progress.unpublish() }
        published.removeAll()
    }
}
