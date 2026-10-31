import XCTest

/// Ein Pfad durch das Karten-UI mit Fakes (`-uiTestFakes`, nur Debug): kein Netz, keine Keychain, kein CoreLocation.
/// Abdeckung: erster Start mit Schluessel, Planen mit einem Suchfeld (Geraet, Server-Zeile), Verbindungsliste, Quellen-Link, Fahrtdetails, Einstellungen.
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

        // 1 Start -> 2 Planen: ein Feld, Text geht erst nach Tipp auf die Server-Zeile ans Backend;
        // ein Ziel waehlen plant sofort ab "Mein Standort"
        tap(app.buttons["searchEntry"])
        let search = app.textFields["searchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("Köln\n")
        tap(app.buttons["serverSearchRow"])
        tap(app.buttons["searchResult"].firstMatch)

        // 3 Routenauswahl: Hero Card, Alternativen, Quellenangabe
        XCTAssertTrue(app.buttons["heroCard"].waitForExistence(timeout: 10))
        let sourceLink = app.descendants(matching: .any)["attributionLink.Transitous-Datenquellen"]
        XCTAssertTrue(sourceLink.waitForExistence(timeout: 5))
        XCTAssertEqual(sourceLink.label, "Transitous-Datenquellen")
        XCTAssertTrue(sourceLink.isHittable, "Quellenangabe muss im mittleren Detent sichtbar sein")

        // Planen: beide Felder gefuellt (Hauptknopf da), Zeit-Chip, anderer Start per Adresse plant sofort
        tap(app.buttons["optionsButton"])
        XCTAssertTrue(app.segmentedControls["timeMode"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["planButton"].exists)
        tap(app.buttons["originRow"])
        let addressField = app.textFields["searchField"]
        XCTAssertTrue(addressField.waitForExistence(timeout: 5))
        addressField.typeText("Musterstr")
        tap(app.buttons["searchResult"].firstMatch)
        XCTAssertTrue(app.buttons["heroCard"].waitForExistence(timeout: 10))

        // 3d Fahrtdetails als Zustand im Sheet; eine Richtung zurueck: Details > Ergebnisse > Planen
        tap(app.buttons["heroCard"])
        XCTAssertTrue(app.buttons["backToRoutes"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Ersatzverkehr")).firstMatch
            .waitForExistence(timeout: 5))
        tap(app.buttons["backToRoutes"])
        XCTAssertTrue(app.buttons["heroCard"].waitForExistence(timeout: 5))
        tap(app.buttons["backToPlan"])
        XCTAssertTrue(app.buttons["planButton"].waitForExistence(timeout: 5), "Eingaben bleiben, Suchen ist ein Tipp entfernt")
        tap(app.buttons["planButton"])
        XCTAssertTrue(app.buttons["heroCard"].waitForExistence(timeout: 10))

        // G1 Einstellungen -> Dein Server (Einstellungen nur auf Start und Planen, nicht auf der Routenauswahl)
        tap(app.buttons["backToPlan"])
        XCTAssertTrue(app.buttons["settingsButton"].firstMatch.waitForExistence(timeout: 5))
        tap(app.buttons["settingsButton"].firstMatch)
        tap(app.buttons["serverKeyLink"])
        XCTAssertTrue(app.staticTexts["Schlüssel gespeichert"].waitForExistence(timeout: 5))
    }

    /// Unterwegs ist die Karte bedienbar: Verschieben stoppt das Folgen, "Zentrieren" holt es zurueck.
    @MainActor
    func testNavigationMapIsInteractive() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFakes", "-fakeOnboarded", "-fakeNow", "2026-10-24T06:01:00Z",
                               "-fakePosition", "51.2201,6.7915"]
        app.launch()
        tap(app.buttons["searchEntry"])
        let search = app.textFields["searchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("Köln\n")
        tap(app.buttons["serverSearchRow"])
        tap(app.buttons["searchResult"].firstMatch)
        tap(app.buttons["startButton"].firstMatch)
        XCTAssertTrue(app.descendants(matching: .any)["nowCard"].waitForExistence(timeout: 10))

        let recenter = app.buttons["recenterMap"]
        XCTAssertFalse(recenter.exists, "Kamera folgt zu Beginn, kein Zentrieren-Knopf")
        // Zwischen Jetzt-Karte und Danach-Sheet auf der Karte ziehen.
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        from.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.45)))
        XCTAssertTrue(recenter.waitForExistence(timeout: 5), "Karte muss unterwegs verschiebbar sein")
        recenter.tap()
        XCTAssertTrue(recenter.waitForNonExistence(timeout: 5))
    }

    /// Restfahrt: Kopf mit engster Stelle, "Ganze Route" pausiert das Folgen, Zeile antippen zeigt den Punkt.
    @MainActor
    func testNavigationOverviewShowsTightestAndMovesMap() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFakes", "-fakeOnboarded", "-fakeScenario", "deutz", "-fakeNow", "2026-10-26T07:10:00Z",
                               "-fakePosition", "51.0500,6.9000"]
        app.launch()
        tap(app.buttons["searchEntry"])
        let search = app.textFields["searchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("Köln\n")
        tap(app.buttons["serverSearchRow"])
        tap(app.buttons["searchResult"].firstMatch)
        tap(app.buttons["startButton"].firstMatch)
        XCTAssertTrue(app.descendants(matching: .any)["nowCard"].waitForExistence(timeout: 10))

        let header = app.descendants(matching: .any)["overviewHeader"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        XCTAssertTrue(header.label.contains("8 Etappen"), header.label)
        let tightest = app.buttons["tightestTransfer"]
        XCTAssertTrue(tightest.waitForExistence(timeout: 5))
        // Gehzeit kalibriert (Fake-MKDirections), daher nur Halt und Einheit pruefen.
        XCTAssertTrue(tightest.label.hasPrefix("Engster Umstieg: Köln Messe/Deutz, ") && tightest.label.hasSuffix("Sekunden"),
                      tightest.label)
        // Kompakt: aktuelle und naechste Etappe sichtbar
        let rows = app.buttons.matching(identifier: "overviewRow")
        XCTAssertTrue(rows.element(boundBy: 1).waitForExistence(timeout: 5))
        XCTAssertTrue(rows.element(boundBy: 0).isHittable && rows.element(boundBy: 1).isHittable)
        XCTAssertTrue(rows.element(boundBy: 0).label.hasPrefix("Jetzt"))

        let recenter = app.buttons["recenterMap"]
        tap(app.buttons["fitRoute"])
        XCTAssertTrue(recenter.waitForExistence(timeout: 5), "Ganze Route pausiert das Folgen")
        recenter.tap()
        XCTAssertTrue(recenter.waitForNonExistence(timeout: 5))
        rows.element(boundBy: 1).tap()
        XCTAssertTrue(recenter.waitForExistence(timeout: 5), "Zeile zeigt den Punkt, Folgen pausiert")
    }

    /// Start (B1, 27.10.): Leerzustand "Zuhause festlegen", Wahl wird Favorit ohne Suche; Tipp auf die Kachel sucht sofort.
    @MainActor
    func testStartFavoriteTileSearchesImmediately() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFakes", "-fakeOnboarded"]
        app.launch()
        XCTAssertTrue(app.buttons["nearbyStop"].firstMatch.waitForExistence(timeout: 10), "Haltestellen in der Nähe im Start")
        tap(app.buttons["setHome"])
        let search = app.textFields["searchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("Köln\n")
        tap(app.buttons["serverSearchRow"])
        tap(app.buttons["searchResult"].firstMatch)

        let home = app.buttons["favoriteTile.home"]
        XCTAssertTrue(home.waitForExistence(timeout: 5), "Zurück im Start mit Kachel Zuhause")
        XCTAssertTrue(home.label.hasPrefix("Zuhause, "), home.label)
        XCTAssertTrue(app.buttons["favoriteTile.uni"].exists && app.buttons["favoriteTile.add"].exists)
        home.tap()
        XCTAssertTrue(app.buttons["heroCard"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "fehlt: \(element)", file: file, line: line)
        element.tap()
    }
}
