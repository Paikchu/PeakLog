import SwiftUI
import XCTest
@testable import PeakLog

@MainActor
final class ThemeManagerTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // An isolated suite per test: the real appearance choice lives in
        // `.standard` and must not be read or clobbered by tests.
        suiteName = "peaklog.theme-manager-tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Startup resolution

    func testFreshInstallDefaultsToDark() {
        let manager = ThemeManager(defaults: defaults)

        XCTAssertEqual(manager.mode, .dark)
        XCTAssertEqual(manager.preferredColorScheme, .dark)
    }

    func testLegacyDarkModeTrueMigratesToDark() {
        defaults.set(true, forKey: "peaklog.isDarkMode")

        XCTAssertEqual(ThemeManager(defaults: defaults).mode, .dark)
    }

    /// The upgrade must not quietly move someone off light and onto
    /// "follow system" — which on a dark device would look like a regression.
    func testLegacyDarkModeFalseMigratesToLight() {
        defaults.set(false, forKey: "peaklog.isDarkMode")

        XCTAssertEqual(ThemeManager(defaults: defaults).mode, .light)
    }

    func testStoredModeWinsOverLegacyKey() {
        defaults.set(true, forKey: "peaklog.isDarkMode")
        defaults.set("system", forKey: "peaklog.appearanceMode")

        XCTAssertEqual(ThemeManager(defaults: defaults).mode, .system)
    }

    func testUnrecognizedStoredModeFallsBackToTheLegacyKey() {
        defaults.set(false, forKey: "peaklog.isDarkMode")
        defaults.set("sepia", forKey: "peaklog.appearanceMode")

        XCTAssertEqual(ThemeManager(defaults: defaults).mode, .light)
    }

    func testModeChangePersistsAcrossLaunches() {
        let manager = ThemeManager(defaults: defaults)
        manager.mode = .system

        XCTAssertEqual(ThemeManager(defaults: defaults).mode, .system)
    }

    // MARK: - Resolution for sheets

    /// Sheets are handed `resolvedColorScheme`, which in `system` mode is
    /// whatever the app root last observed the device rendering in.
    func testResolvedColorSchemeFollowsTheDeviceInSystemMode() {
        let manager = ThemeManager(defaults: defaults)
        manager.mode = .system

        manager.recordSystemColorScheme(.light)
        XCTAssertNil(manager.preferredColorScheme, "system mode must leave the window unoverridden")
        XCTAssertEqual(manager.resolvedColorScheme, .light)

        manager.recordSystemColorScheme(.dark)
        XCTAssertEqual(manager.resolvedColorScheme, .dark)
    }

    func testResolvedColorSchemeIsThePinnedModeRegardlessOfTheDevice() {
        let manager = ThemeManager(defaults: defaults)
        manager.mode = .system
        manager.recordSystemColorScheme(.dark)

        manager.mode = .light

        XCTAssertEqual(manager.preferredColorScheme, .light)
        XCTAssertEqual(manager.resolvedColorScheme, .light)
    }

    /// While an override is in place the app root renders in the override,
    /// not the device setting — so what it reports back is not a reading of
    /// the device and must be ignored.
    func testRecordSystemColorSchemeIsIgnoredWhilePinned() {
        let manager = ThemeManager(defaults: defaults)
        manager.mode = .system
        manager.recordSystemColorScheme(.dark)

        manager.mode = .light
        manager.recordSystemColorScheme(.light)
        manager.mode = .system

        XCTAssertEqual(manager.resolvedColorScheme, .dark,
                       "the pinned scheme must not be mistaken for the device's")
    }
}
