import XCTest

/// Ein Pfad durch das Karten-UI mit Fakes (`-uiTestFakes`, nur Debug): kein Netz, keine Keychain, kein CoreLocation.
/// Abdeckung: erster Start mit Schluessel, beide Suchmodi, Verbindungsliste, Quellen-Link, Fahrtdetails, Einstellungen.
final class PlanFlowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testOnboardingSearchPlanDetailsAndSources() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFakes"]
        app.launch()

        // A1 Erster Start, A2 Dein Server
        tap(app.buttons["welcomeContinue"])
        let field = app.secureTextFields["serverKeyField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(String(repeating: "k", count: 40))
        tap(app.buttons["saveServerKey"])
        XCTAssertTrue(app.staticTexts["Schlüssel gespeichert"].waitForExistence(timeout: 5))
        tap(app.buttons["onboardingDone"])

        // 1 Start -> 2 Suche (Modus Haltestelle) -> Ziel waehlen plant sofort ab "Mein Standort"
        tap(app.buttons["searchEntry"])
        tap(app.buttons["Haltestelle"])
        XCTAssertTrue(app.staticTexts["Der Suchtext geht ohne Standort an den Fahrplan-Server."].waitForExistence(timeout: 5))
        let search = app.textFields["searchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("Köln\n")
        tap(app.buttons["searchResult"].firstMatch)

        // 3 Routenauswahl: Hero Card, Alternativen, Quellenangabe
        XCTAssertTrue(app.buttons["heroCard"].waitForExistence(timeout: 10))
        let sourceLink = app.descendants(matching: .any)["attributionLink.Transitous-Datenquellen"]
        XCTAssertTrue(sourceLink.waitForExistence(timeout: 5))
        XCTAssertEqual(sourceLink.label, "Transitous-Datenquellen")
        XCTAssertTrue(sourceLink.isHittable, "Quellenangabe muss im mittleren Detent sichtbar sein")

        // 2c: anderer Start per Adresssuche, dann neu suchen
        tap(app.buttons["optionsButton"])
        tap(app.buttons["originRow"])
        tap(app.buttons["Adresse"])
        let addressField = app.textFields["searchField"]
        XCTAssertTrue(addressField.waitForExistence(timeout: 5))
        addressField.tap()
        addressField.typeText("Musterstr")
        tap(app.buttons["searchResult"].firstMatch)
        XCTAssertTrue(app.staticTexts["Musterstraße 1"].waitForExistence(timeout: 5))
        tap(app.buttons["planButton"])

        // 3d Fahrtdetails als Zustand im Sheet, zurueck zur Liste
        tap(app.buttons["heroCard"])
        XCTAssertTrue(app.buttons["backToRoutes"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Ersatzverkehr")).firstMatch
            .waitForExistence(timeout: 5))
        tap(app.buttons["backToRoutes"])
        XCTAssertTrue(app.buttons["heroCard"].waitForExistence(timeout: 5))

        // G1 Einstellungen -> Dein Server
        tap(app.buttons["settingsButton"].firstMatch)
        tap(app.buttons["serverKeyLink"])
        XCTAssertTrue(app.staticTexts["Schlüssel gespeichert"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "fehlt: \(element)", file: file, line: line)
        element.tap()
    }
}
