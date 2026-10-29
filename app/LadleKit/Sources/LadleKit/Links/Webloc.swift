import Foundation

/// Reads the link out of a `.webloc` file (a property list with a `URL` key) dropped on Ladle.
public enum Webloc {
    public static func url(fromFileAt fileURL: URL) -> URL? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return url(fromData: data)
    }

    public static func url(fromData data: Data) -> URL? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any],
              let string = dict["URL"] as? String else { return nil }
        return LinkParser.link(from: string)
    }
}
