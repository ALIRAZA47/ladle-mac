import XCTest
@testable import Ladle

/// The app's own pieces that don't need a window. The engine is tested in LadleKit.
final class LadleAppTests: XCTestCase {
    func testLinksMatchTheSpec() {
        XCTAssertEqual(LadleLinks.website.absoluteString, "https://ladle.alirazakhan.me/")
        XCTAssertEqual(LadleLinks.changelog.absoluteString, "https://ladle.alirazakhan.me/changelog/")
        XCTAssertEqual(LadleLinks.support.absoluteString, "https://github.com/ALIRAZA47/ladle-mac/issues")
        XCTAssertEqual(LadleLinks.setUpSafari.absoluteString, "https://ladle.alirazakhan.me/docs/getting-started/set-up-your-browser/#safari")
        XCTAssertEqual(LadleLinks.menuBarDockAndNotifications.absoluteString, "https://ladle.alirazakhan.me/docs/getting-started/menu-bar-dock-and-notifications/")
        XCTAssertEqual(LadleLinks.updates.absoluteString, "https://ladle.alirazakhan.me/docs/updates/")
        XCTAssertEqual(LadleLinks.releaseNotes(version: "1.0.0").absoluteString, "https://ladle.alirazakhan.me/changelog/#v1-0-0")
    }

    @MainActor
    func testBrowserFamilies() {
        XCTAssertEqual(BrowserIntegration.family(forBrowser: "Firefox"), .firefox)
        XCTAssertEqual(BrowserIntegration.family(forBrowser: "Arc"), .chrome)
        XCTAssertEqual(BrowserIntegration.family(forBrowser: "Edge"), .chrome)
    }

    func testSafariNeedsADeveloperSignedBuild() {
        XCTAssertEqual(SafariExtensionStatus(teamIdentifier: nil, enabled: true), .needsSignedBuild)
        XCTAssertEqual(SafariExtensionStatus(teamIdentifier: "", enabled: nil), .needsSignedBuild)
        XCTAssertEqual(SafariExtensionStatus(teamIdentifier: "ABCDE12345", enabled: true), .on)
        XCTAssertEqual(SafariExtensionStatus(teamIdentifier: "ABCDE12345", enabled: false), .off)
        XCTAssertEqual(SafariExtensionStatus(teamIdentifier: "ABCDE12345", enabled: nil), .unknown)
        XCTAssertEqual(SafariExtensionStatus.needsSignedBuild.text, "The Safari extension needs a signed build of Ladle")
        // CI's test host is ad-hoc signed; a build signed by a team has a 10-character team ID.
        if let team = CodeSignature.teamIdentifier {
            XCTAssertEqual(team.count, 10)
        }
    }

    func testInfoPlistCarriesTheUpdateSettings() throws {
        let info = try XCTUnwrap(Bundle(for: AppModel.self).infoDictionary)
        XCTAssertEqual(info["SUFeedURL"] as? String, "https://ladle.alirazakhan.me/appcast.xml")
        XCTAssertEqual(info["SUScheduledCheckInterval"] as? Int, 86400)
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(info["SUAutomaticallyUpdate"] as? Bool, true)
        XCTAssertEqual(info["SUEnableSystemProfiling"] as? Bool, false)
        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, "0.1.2")
    }
}
