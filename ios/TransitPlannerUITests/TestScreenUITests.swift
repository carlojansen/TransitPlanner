import XCTest

/// Ein Pfad durch den Testbildschirm mit Fakes (`-uiTestFakes`, nur Debug): kein Netz, keine Keychain, kein Standort.
final class TestScreenUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testServerKeySearchPlanAndAttribution() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFakes"]
        app.launch()

        // a) Server-Schluessel speichern
        app.buttons["settingsButton"].tap()
        app.buttons["serverKeyLink"].tap()
        let field = app.secureTextFields["serverKeyField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(String(repeating: "k", count: 40))
        app.buttons["saveServerKey"].tap()
        XCTAssertTrue(app.staticTexts["Schlüssel gespeichert"].waitForExistence(timeout: 5))
        app.navigationBars["Dein Server"].buttons["BackButton"].tap()
        let done = app.navigationBars["Einstellungen"].buttons["Fertig"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()

        // b) Start im Standardmodus "Adresse"
        app.buttons["originRow"].tap()
        let addressMode = app.buttons["Adresse"]
        XCTAssertTrue(addressMode.waitForExistence(timeout: 5))
        XCTAssertTrue(addressMode.isSelected)
        let search = app.textFields["searchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("Musterstr")
        let result = app.buttons["searchResult"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.tap()

        // Ziel im Modus "Haltestelle"
        let destinationRow = app.buttons["destinationRow"]
        XCTAssertTrue(destinationRow.waitForExistence(timeout: 5))
        destinationRow.tap()
        app.buttons["Haltestelle"].tap()
        XCTAssertTrue(app.staticTexts["Der Suchtext geht ohne Standort an den Fahrplan-Server."].waitForExistence(timeout: 5))
        app.textFields["searchField"].typeText("Köln\n")
        let stop = app.buttons["searchResult"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()

        // c) Verbindungsliste, d) Quellenangabe mit Link
        let plan = app.buttons["planButton"]
        XCTAssertTrue(plan.waitForExistence(timeout: 5))
        plan.tap()
        XCTAssertTrue(app.buttons["journeyRow"].firstMatch.waitForExistence(timeout: 5))
        // Im List-Footer erscheint ein Link je nach System als Link oder Button: ueber die eigene Kennung suchen.
        let sourceLink = app.descendants(matching: .any)["attributionLink.Transitous-Datenquellen"]
        XCTAssertTrue(sourceLink.waitForExistence(timeout: 5))
        XCTAssertEqual(sourceLink.label, "Transitous-Datenquellen")

        // Fahrtdetails als Zustand, zurueck zur Liste
        app.buttons["journeyRow"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Ersatzverkehr"].waitForExistence(timeout: 5))
        app.buttons["backButton"].tap()
        XCTAssertTrue(app.buttons["journeyRow"].firstMatch.waitForExistence(timeout: 5))
    }
}
