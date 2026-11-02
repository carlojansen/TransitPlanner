import XCTest

/// Screenshot-Durchlauf fuer den visuellen Abgleich mit Figma (nur mit Fakes, kein Netz).
/// Laeuft nur mit SCREENSHOTS=1 (beim Aufruf per xcodebuild: TEST_RUNNER_SCREENSHOTS=1), sonst uebersprungen.
/// Ziel: $SCREENSHOT_DIR (TEST_RUNNER_SCREENSHOT_DIR), Dateinamen wie `09-routes-light.png`.
final class ScreenshotTour: XCTestCase {
    static let defaultDir = NSTemporaryDirectory() + "transitplanner-shots"

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
        // TOUR_ONLY=<Teil des Namens> (TEST_RUNNER_TOUR_ONLY): nur passende Navigationszustaende, z. B. "4b".
        if let only = ProcessInfo.processInfo.environment["TOUR_ONLY"], !only.isEmpty {
            for mode in ["light", "dark"] {
                for state in Self.navigationStates where state.name.contains(only) {
                    try navigation(mode, state, ax3: false)
                    if state.ax3 { try navigation(mode, state, ax3: true) }
                }
            }
            return
        }
        for mode in ["light", "dark"] {
            try onboardingAndPlanning(mode)
            try routesAndDetails(mode, ax3: false)
            try routesAndDetails(mode, ax3: true)
            try loading(mode)
            try singleState(mode, scenario: "serverDown", name: "14-h1-banner", waitFor: "banner")
            try singleState(mode, scenario: "noConnections", name: "15-h2-no-connections", waitFor: nil)
            try offline(mode)
            for state in Self.navigationStates {
                try navigation(mode, state, ax3: false)
                if state.ax3 { try navigation(mode, state, ax3: true) }
            }
        }
    }

    /// Unterwegs (DESIGN.md C) mit Fake-Uhr und Fake-Standort entlang der Fake-Verbindung 0
    /// (Fussweg > STR 704 06:08 > Umstieg > SEV RE 5 06:23-06:38 > Fussweg).
    struct NavState {
        let name: String
        let now: String
        let position: String
        var ax3 = false
        /// Restfahrt-Fixture `-fakeScenario deutz` (26.10.) statt Fake-Verbindung 0 (24.10.)
        var deutz = false
        /// Danach-Sheet auf den mittleren Detent ziehen
        var expand = false
    }

    static let navigationStates = [
        NavState(name: "18-nav-4-walk", now: "06:01:00", position: "51.2201,6.7915", ax3: true),
        NavState(name: "19-nav-4b-platform", now: "06:05:00", position: "51.21996,6.79432"),
        NavState(name: "20-nav-4c-onboard", now: "06:12:00", position: "51.2120,6.7850"),
        NavState(name: "21-nav-4d-transfer", now: "06:17:00", position: "51.2045,6.7755"),
        NavState(name: "22-nav-4e-replacement", now: "06:21:00", position: "51.2049,6.7761", ax3: true),
        NavState(name: "23-nav-final-walk", now: "06:39:00", position: "50.9425,6.9587"),
        NavState(name: "24-nav-4f-arrival", now: "06:43:00", position: "50.9413,6.9583"),
        // Restfahrt: im ICE (Deutz knapp), mittlerer Detent, Umstieg an Gleis 93 (aktuell, live).
        NavState(name: "25-nav-overview", now: "07:10:00", position: "51.0500,6.9000", ax3: true, deutz: true),
        NavState(name: "26-nav-overview-medium", now: "07:10:00", position: "51.0500,6.9000", ax3: true, deutz: true,
                 expand: true),
        NavState(name: "27-nav-overview-transfer", now: "07:33:00", position: "50.9409,6.9750", deutz: true, expand: true),
    ]

    @MainActor
    private func navigation(_ mode: String, _ state: NavState, ax3: Bool) throws {
        let app = launch(mode, scenario: state.deutz ? "deutz" : nil, ax3: ax3,
                         extra: ["-fakeNow", "\(state.deutz ? "2026-10-26" : "2026-10-24")T\(state.now)Z",
                                 "-fakePosition", state.position])
        searchStop(app)
        tap(app.buttons["startButton"].firstMatch)
        XCTAssertTrue(app.descendants(matching: .any)["nowCard"].waitForExistence(timeout: 10))
        if state.expand {
            let header = app.descendants(matching: .any)["overviewHeader"]
            XCTAssertTrue(header.waitForExistence(timeout: 5))
            // Am Griff ziehen (knapp ueber dem Kopf): Inhalt scrollt sonst bei AX-Groessen statt das Sheet zu heben.
            header.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 150, dy: -20))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
        }
        shot(app, state.name, mode, ax3 ? "-ax3" : "")
        app.terminate()
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
        // Start mit Favorit: Zuhause ueber den Leerzustand festlegen
        tap(app.buttons["setHome"])
        type(app, "Köln\n")
        tap(app.buttons["serverSearchRow"])
        tap(app.buttons["searchResult"].firstMatch)
        XCTAssertTrue(app.buttons["favoriteTile.home"].waitForExistence(timeout: 5))
        shot(app, "04c-start-favorites", mode)

        tap(app.buttons["searchEntry"])
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 5))
        shot(app, "04b-plan-empty", mode)
        type(app, "Musterstr\n")
        XCTAssertTrue(app.buttons["searchResult"].firstMatch.waitForExistence(timeout: 5))
        shot(app, "06-search-address", mode)
        tap(app.buttons["serverSearchRow"])
        XCTAssertTrue(app.buttons["searchResult"].firstMatch.waitForExistence(timeout: 5))
        shot(app, "05-search-stops", mode)
        tap(app.buttons["cancelSearch"])

        // Beste Verbindung mit Ersatzverkehr (3e)
        searchStop(app)
        XCTAssertTrue(app.buttons["heroCard"].waitForExistence(timeout: 10))
        shot(app, "10-routes-sev", mode)
        tap(app.buttons["optionsButton"])
        XCTAssertTrue(app.buttons["planButton"].waitForExistence(timeout: 5))
        shot(app, "07-options", mode)
        tap(app.buttons["planButton"])
        tap(app.buttons["heroCard"])
        XCTAssertTrue(app.buttons["backToRoutes"].waitForExistence(timeout: 5))
        shot(app, "11-details-sev", mode)
        tap(app.buttons["backToRoutes"])
        // Einstellungen nur auf Start und Planen, nicht auf der Routenauswahl
        tap(app.buttons["backToPlan"])
        XCTAssertTrue(app.buttons["settingsButton"].firstMatch.waitForExistence(timeout: 5))

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
    private func launch(_ mode: String, onboarded: Bool = true, scenario: String? = nil, ax3: Bool = false,
                        extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-uiTestFakes", mode == "dark" ? "-uiTestDark" : "-uiTestLight"]
        if onboarded { args.append("-fakeOnboarded") }
        if let scenario { args += ["-fakeScenario", scenario] }
        // accessibility3 = UIKit "AccessibilityXL"
        if ax3 { args += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"] }
        app.launchArguments = args + extra
        app.launch()
        return app
    }

    @MainActor
    private func searchStop(_ app: XCUIApplication) {
        tap(app.buttons["searchEntry"])
        type(app, "Köln\n")
        tap(app.buttons["serverSearchRow"])
        tap(app.buttons["searchResult"].firstMatch)
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
