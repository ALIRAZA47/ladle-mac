import XCTest
@testable import LadleKit

final class FileNamingTests: XCTestCase {
    func testExtensions() {
        XCTAssertEqual(FileNaming.fileExtension(of: "ubuntu-24.04.2-desktop-amd64.iso"), "iso")
        XCTAssertEqual(FileNaming.fileExtension(of: "Photo.JPG"), "jpg")
        XCTAssertEqual(FileNaming.fileExtension(of: "README"), "")
        XCTAssertEqual(FileNaming.fileExtension(of: ".hidden"), "")
        XCTAssertEqual(FileNaming.fileExtension(of: "archive.tar.gz"), "gz")
        XCTAssertEqual(FileNaming.splitExtension("archive.tar.gz").stem, "archive")
        XCTAssertEqual(FileNaming.splitExtension("archive.tar.gz").ext, ".tar.gz")
        XCTAssertEqual(FileNaming.splitExtension("notes").ext, "")
    }

    func testSanitizesNames() {
        XCTAssertEqual(FileNaming.sanitize("a/b:c.zip"), "a-b-c.zip")
        XCTAssertEqual(FileNaming.sanitize("  ..secret.txt "), "secret.txt")
        XCTAssertEqual(FileNaming.sanitize("\u{0007}bell\n.txt"), "bell.txt")
        XCTAssertEqual(FileNaming.sanitize("   "), "download")
        let long = String(repeating: "x", count: 400) + ".mp4"
        let cut = FileNaming.sanitize(long)
        XCTAssertLessThanOrEqual(cut.utf8.count, 200)
        XCTAssertTrue(cut.hasSuffix(".mp4"))
    }

    func testNamesFromLinks() {
        XCTAssertEqual(FileNaming.nameFromURL(URL(string: "https://a.org/dir/My%20File.pdf?x=1")!), "My File.pdf")
        XCTAssertNil(FileNaming.nameFromURL(URL(string: "https://a.org/")!))
        XCTAssertEqual(FileNaming.suggestedName(url: URL(string: "https://a.org/")!), "a.org")
        XCTAssertEqual(FileNaming.suggestedName(url: URL(string: "https://a.org/download")!, mimeType: "application/pdf; charset=binary"), "download.pdf")
        XCTAssertEqual(FileNaming.suggestedName(url: URL(string: "https://a.org/x.bin")!, mimeType: "application/pdf"), "x.bin")
    }

    func testContentDisposition() {
        XCTAssertEqual(FileNaming.nameFromContentDisposition("attachment; filename=\"HandBrake-1.8.2.dmg\""), "HandBrake-1.8.2.dmg")
        XCTAssertEqual(FileNaming.nameFromContentDisposition("attachment; filename=plain.zip"), "plain.zip")
        XCTAssertEqual(FileNaming.nameFromContentDisposition("attachment; filename=\"fallback.txt\"; filename*=UTF-8''%E2%82%AC%20rates.txt"), "€ rates.txt")
        XCTAssertEqual(FileNaming.nameFromContentDisposition("inline; filename=\"a;b.txt\""), "a;b.txt")
        XCTAssertEqual(FileNaming.nameFromContentDisposition("attachment; filename=\"../../etc/passwd\""), "passwd")
        XCTAssertEqual(FileNaming.nameFromContentDisposition("attachment; filename=\"say \\\"hi\\\".txt\""), "say \"hi\".txt")
        XCTAssertNil(FileNaming.nameFromContentDisposition("inline"))
    }

    func testKeepBothNames() {
        var taken: Set<String> = ["report.pdf", "report 2.pdf"]
        XCTAssertEqual(FileNaming.availableName(for: "report.pdf", isTaken: taken.contains), "report 3.pdf")
        XCTAssertEqual(FileNaming.availableName(for: "new.pdf", isTaken: taken.contains), "new.pdf")
        taken = ["backup.tar.gz"]
        XCTAssertEqual(FileNaming.availableName(for: "backup.tar.gz", isTaken: taken.contains), "backup 2.tar.gz")
        taken = ["Makefile"]
        XCTAssertEqual(FileNaming.availableName(for: "Makefile", isTaken: taken.contains), "Makefile 2")
    }

    func testNormalizesExtensionLists() {
        XCTAssertEqual(FileNaming.normalizedExtensions([".DMG", "pkg", " zip ", "dmg", "", "a b", "tar.gz"]), ["dmg", "pkg", "zip"])
    }

    func testCategoriesFollowTheSpecTable() {
        XCTAssertEqual(FileCategory.forFileName("a.MKV"), .video)
        XCTAssertEqual(FileCategory.forFileName("a.ts"), .video)
        XCTAssertEqual(FileCategory.forFileName("a.flac"), .music)
        XCTAssertEqual(FileCategory.forFileName("a.key"), .documents)
        XCTAssertEqual(FileCategory.forFileName("a.tgz"), .archives)
        XCTAssertEqual(FileCategory.forFileName("a.tar.gz"), .archives)
        XCTAssertEqual(FileCategory.forFileName("a.app"), .apps)
        XCTAssertEqual(FileCategory.forFileName("a.heic"), .images)
        XCTAssertEqual(FileCategory.forFileName("a.exe"), .other)
        XCTAssertEqual(FileCategory.forFileName("noext"), .other)
        XCTAssertNil(FileCategory.other.folderName)
        XCTAssertEqual(FileCategory.knownExtensions.count, 7 + 6 + 9 + 8 + 4 + 8)
    }

    func testDestinationFolders() {
        let home = URL(fileURLWithPath: "/Users/ali", isDirectory: true)
        var settings = Settings()
        XCTAssertEqual(Destination.folder(for: .video, settings: settings, home: home).path, "/Users/ali/Downloads/Ladle/Video")
        XCTAssertEqual(Destination.folder(for: .other, settings: settings, home: home).path, "/Users/ali/Downloads/Ladle")
        settings.sortIntoCategoryFolders = false
        XCTAssertEqual(Destination.folder(for: .video, settings: settings, home: home).path, "/Users/ali/Downloads/Ladle")
        settings.saveFolderPath = "/Volumes/Big/Incoming"
        XCTAssertEqual(Destination.folder(for: .apps, settings: settings, home: home).path, "/Volumes/Big/Incoming")
        XCTAssertEqual(Destination.displayPath("/Users/ali/Downloads/Ladle/Video", home: home), "Downloads › Ladle › Video")
        XCTAssertEqual(Destination.displayPath("/Volumes/Big/Incoming", home: home), "Volumes › Big › Incoming")
    }

    func testNameIsTakenByPartFiles() throws {
        let folder = TempFolder()
        try Data().write(to: folder.file("a.zip.ladle-part"))
        try Data().write(to: folder.file("b.zip"))
        XCTAssertTrue(Destination.nameIsTaken("a.zip", in: folder.url))
        XCTAssertTrue(Destination.nameIsTaken("b.zip", in: folder.url))
        XCTAssertFalse(Destination.nameIsTaken("c.zip", in: folder.url))
    }

    func testPartFileWritesAtOffsets() throws {
        let folder = TempFolder()
        let part = try PartFile(url: folder.file("x.ladle-part"), truncate: true)
        try part.preallocate(size: 10)
        XCTAssertEqual(try part.length(), 10)
        try part.write(Data([5, 6, 7]), at: 5)
        try part.write(Data([1, 2]), at: 0)
        try part.sync()
        XCTAssertEqual(try part.read(count: 10, at: 0), Data([1, 2, 0, 0, 0, 5, 6, 7, 0, 0]))
        part.close()
        part.close()
        XCTAssertThrowsError(try PartFile(url: URL(fileURLWithPath: "/nonexistent-dir/x")))
    }
}
