import Foundation

/// Where a file goes, and how that place is written in the interface ("Downloads › Ladle › Video").
public enum Destination {
    public static func folder(for category: FileCategory, settings: Settings, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let base = settings.saveFolder(home: home)
        guard settings.sortIntoCategoryFolders, let sub = category.folderName else { return base }
        return base.appendingPathComponent(sub, isDirectory: true)
    }

    /// Folder path relative to the home folder, joined with " › ".
    public static func displayPath(_ folder: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let homePath = home.standardizedFileURL.path
        var path = URL(fileURLWithPath: folder).standardizedFileURL.path
        if path == homePath { return "Home" }
        if path.hasPrefix(homePath + "/") {
            path = String(path.dropFirst(homePath.count + 1))
        }
        let parts = path.split(separator: "/").map(String.init)
        return parts.isEmpty ? "/" : parts.joined(separator: " › ")
    }

    /// Whether `name` is in use in `folder` as a finished file or a part file.
    public static func nameIsTaken(_ name: String, in folder: URL, fileManager: FileManager = .default) -> Bool {
        let target = folder.appendingPathComponent(name)
        if fileManager.fileExists(atPath: target.path) { return true }
        return fileManager.fileExists(atPath: target.path + FileNaming.partSuffix)
    }
}
