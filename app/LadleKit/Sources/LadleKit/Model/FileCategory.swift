import Foundation

/// The folders downloads are sorted into, by file extension (see SPEC "Files and folders").
public enum FileCategory: String, Codable, CaseIterable, Sendable {
    case video
    case music
    case documents
    case archives
    case apps
    case images
    case other

    /// Name of the subfolder inside the save folder. `nil` means the save folder itself.
    public var folderName: String? {
        switch self {
        case .video: return "Video"
        case .music: return "Music"
        case .documents: return "Documents"
        case .archives: return "Archives"
        case .apps: return "Apps"
        case .images: return "Images"
        case .other: return nil
        }
    }

    /// Label in the sidebar.
    public var title: String {
        folderName ?? "Downloads"
    }

    public var extensions: [String] {
        switch self {
        case .video: return ["mp4", "mov", "mkv", "webm", "avi", "m4v", "ts"]
        case .music: return ["mp3", "flac", "wav", "m4a", "aac", "ogg"]
        case .documents: return ["pdf", "epub", "doc", "docx", "txt", "pages", "key", "xlsx", "csv"]
        case .archives: return ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"]
        case .apps: return ["dmg", "pkg", "iso", "app"]
        case .images: return ["png", "jpg", "jpeg", "heic", "webp", "gif", "svg", "tiff"]
        case .other: return []
        }
    }

    /// The categories shown in the sidebar, in order.
    public static let sorted: [FileCategory] = [.video, .music, .documents, .archives, .apps, .images]

    private static let byExtension: [String: FileCategory] = {
        var map: [String: FileCategory] = [:]
        for category in sorted {
            for ext in category.extensions { map[ext] = category }
        }
        return map
    }()

    public static func forExtension(_ ext: String) -> FileCategory {
        byExtension[ext.lowercased()] ?? .other
    }

    public static func forFileName(_ name: String) -> FileCategory {
        forExtension(FileNaming.fileExtension(of: name))
    }

    /// Every extension Ladle knows. The clipboard banner only offers links to these.
    public static let knownExtensions: Set<String> = Set(sorted.flatMap { $0.extensions })
}
