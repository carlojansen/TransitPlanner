import XCTest

/// Screenshot-Durchlauf fuer den visuellen Abgleich mit Figma (nur mit Fakes, kein Netz).
/// Laeuft nur mit SCREENSHOTS=1 (beim Aufruf per xcodebuild: TEST_RUNNER_SCREENSHOTS=1), sonst uebersprungen.
/// Ziel: $SCREENSHOT_DIR (TEST_RUNNER_SCREENSHOT_DIR), Dateinamen wie `09-routes-light.png`.
final class ScreenshotTour: XCTestCase {
    static let defaultDir = "/private/tmp/claude-501/-Users-carlo-Dev-TransitPlanner/6e8b27d5-d678-4faf-9316-249e57655002/scratchpad/shots"

    private var dir = URL(filePath: ScreenshotTour.defaultDir)

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["SCREENSHOTS"] == "1", "Screenshot-Tour nur mit SCREENSHOTS=1")
        continueAfterFailure = false
        dir = URL(filePath: env["SCREENSHOT_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    @MainActor
    func testTour() throws {
        for mode in ["light", "dark"] {
            try onboardingAndPlanning(mode)
            try routesAndDetails(mode, ax3: false)
            try routesAndDetails(mode, ax3: true)
            try loading(mode)
            try singleState(mode, scenario: "serverDown", name: "14-h1-banner", waitFor: "banner")
            try singleState(mode, scenario: "noConnections", name: "15-h2-no-connections", waitFor: nil)
            try offline(mode)
        }
    }

    // MARK: Durchlaeufe

    /// A1, A2 leer/gespeichert, 1 Start, 2 Haltestelle, 2b Adresse, 3e Ersatzverkehr, 2c, 3d, G1, G2.
    @MainActor
    private func onboardingAndPlanning(_ mode: String) throws {
        let app = launch(mode, onboarded: false)
        XCTAssertTrue(app.buttons["welcomeContinue"].waitForExistence(timeout: 10))
        shot(app, "01-a1-welcome", mode)
        tap(app.buttons["welcomeContinue"])
        let field = app.secureTextFields["serverKeyField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        shot(app, "02-a2-server-empty", mode)
        field.tap()
        field.typeText(String(repeating: "k", count: 40))
        tap(app.buttons["saveServerKey"])
        XCTAssertTrue(app.staticTexts["Schlüssel gespeichert"].waitForExistence(timeout: 5))
        shot(app, "03-a2-server-saved", mode)
        tap(app.buttons["onboardingDone"])
        XCTAssertTrue(app.buttons["searchEntry"].waitForExistence(timeout: 10))
        shot(app, "04-start", mode)

        tap(app.buttons["searchEntry"])
        selectScope(app, "Haltestelle")
        type(app, "Köln\n")
        XCTAssertTrue(app.buttons["searchResult"].firstMatch.waitForExistence(timeout: 5))
        shot(app, "05-search-stops", mode)
        selectScope(app, "Adresse")
        type(app, "Musterstr\n")
        XCTAssertTrue(app.buttons["searchResult"].firstMatch.waitForExistence(timeout: 5))
        shot(app, "06-search-address", mode)
        tap(app.buttons["cancelSearch"])

        // Beste Verbindung mit Ersatzverkehr (3e)
        searchStop(app)
        XCTAssertTrue(app.buttons["heroCard"].waitForExistence(timeout: 10))
        shot(app, "10-routes-sev", mode)
        tap(app.buttons["optionsButton"])
        XCTAssertTrue(app.buttons["planButton"].waitForExistence(timeout: 5))
        shot(app, "07-options", mode)
        tap(app.buttons["Verbindungen"].firstMatch)
        tap(app.buttons["heroCard"])
        XCTAssertTrue(app.buttons["backToRoutes"].waitForExistence(timeout: 5))
        shot(app, "11-details-sev", mode)
        tap(app.buttons["backToRoutes"])

        tap(app.buttons["settingsButton"].firstMatch)
        XCTAssertTrue(app.buttons["serverKeyLink"].waitForExistence(timeout: 5))
        shot(app, "12-g1-settings", mode)
        tap(app.buttons["Quellen und Lizenzen"].firstMatch)
        XCTAssertTrue(app.navigationBars["Quellen und Lizenzen"].waitForExistence(timeout: 5))
        shot(app, "13-g2-sources", mode)
        app.terminate()
    }

    /// 3 Routenauswahl (mittlerer Detent) und 3d Fahrtdetails ohne Ersatzverkehr; mit AX3 zusaetzlich H4.
    @MainActor
    private func routesAndDetails(_ mode: String, ax3: Bool) throws {
        let app = launch(mode, scenario: "plainFirst", ax3: ax3)
        let suffix = ax3 ? "-ax3" : ""
        XCTAssertTrue(app.buttons["searchEntry"].waitForExistence(timeout: 10))
        if ax3 { shot(app, "17-h4-start", mode, suffix) }
        searchStop(app)
        XCTAssertTrue(app.buttons["heroCard"].waitForExistence(timeout: 10))
        shot(app, "09-routes", mode, suffix)
        tap(app.buttons["heroCard"])
        XCTAssertTrue(app.buttons["backToRoutes"].waitForExistence(timeout: 5))
        shot(app, "11-details", mode, suffix)
        app.terminate()
    }

    /// 3a Laden inkl. "Warte auf Verbindung" (nach 3 s).
    @MainActor
    private func loading(_ mode: String) throws {
        let app = launch(mode, scenario: "slow")
        searchStop(app)
        XCTAssertTrue(app.descendants(matching: .any)["waitingRow"].waitForExistence(timeout: 10))
        shot(app, "08-loading", mode)
        app.terminate()
    }

    @MainActor
    private func singleState(_ mode: String, scenario: String, name: String, waitFor identifier: String?) throws {
        let app = launch(mode, scenario: scenario)
        searchStop(app)
        if let identifier {
            XCTAssertTrue(app.descendants(matching: .any)[identifier].waitForExistence(timeout: 10))
        } else {
            XCTAssertTrue(app.staticTexts["Keine Verbindung gefunden"].waitForExistence(timeout: 10))
        }
        shot(app, name, mode)
        app.terminate()
    }

    /// H3: erste Antwort da, Neuplanung offline, letzte Antwort bleibt abgeblendet.
    @MainActor
    private func offline(_ mode: String) throws {
        let app = launch(mode, scenario: "offlineAfterFirst")
        searchStop(app)
        XCTAssertTrue(app.buttons["heroCard"].waitForExistence(timeout: 10))
        tap(app.buttons["optionsButton"])
        tap(app.buttons["planButton"])
        XCTAssertTrue(app.descendants(matching: .any)["banner"].waitForExistence(timeout: 10))
        shot(app, "16-h3-offline", mode)
        app.terminate()
    }

    // MARK: Hilfen

    @MainActor
    private func launch(_ mode: String, onboarded: Bool = true, scenario: String? = nil, ax3: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-uiTestFakes", mode == "dark" ? "-uiTestDark" : "-uiTestLight"]
        if onboarded { args.append("-fakeOnboarded") }
        if let scenario { args += ["-fakeScenario", scenario] }
        // accessibility3 = UIKit "AccessibilityXL"
        if ax3 { args += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"] }
        app.launchArguments = args
        app.launch()
        return app
    }

    @MainActor
    private func searchStop(_ app: XCUIApplication) {
        tap(app.buttons["searchEntry"])
        selectScope(app, "Haltestelle")
        type(app, "Köln\n")
        tap(app.buttons["searchResult"].firstMatch)
    }

    /// Suchmodus sicher setzen (der erste Tipp waehrend der Sheet-Animation geht sonst verloren).
    @MainActor
    private func selectScope(_ app: XCUIApplication, _ label: String) {
        let segment = app.buttons[label]
        for _ in 0..<3 where !segment.isSelected {
            tap(segment)
            Thread.sleep(forTimeInterval: 0.4)
        }
        XCTAssertTrue(segment.isSelected, "Suchmodus \(label) nicht gesetzt")
    }

    @MainActor
    private func type(_ app: XCUIApplication, _ text: String) {
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(text)
    }

    @MainActor
    private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "fehlt: \(element)", file: file, line: line)
        element.tap()
    }

    /// Wartet kurz auf ruhende Animationen und schreibt das PNG.
    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String, _ mode: String, _ suffix: String = "") {
        Thread.sleep(forTimeInterval: 0.8)
        let url = dir.appending(path: "\(name)-\(mode)\(suffix).png")
        do {
            try app.screenshot().pngRepresentation.write(to: url)
        } catch {
            XCTFail("Screenshot \(url.lastPathComponent) nicht geschrieben: \(error)")
        }
    }
}
