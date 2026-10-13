import XCTest

/// Screenshot dell'app con i dati dimostrativi, per vedere come sta venendo.
/// In CI le immagini vengono estratte dal risultato dei test e pubblicate.
final class ScreenshotTests: XCTestCase {
    @MainActor
    func testScreenshots() {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryStore", "-demoData"]
        app.launch()

        let derivata = app.staticTexts["Derivata"].firstMatch
        XCTAssertTrue(derivata.waitForExistence(timeout: 15), "l'elenco con i dati dimostrativi")
        shot("01-elenco")

        derivata.tap()
        XCTAssertTrue(app.buttons["Anteprima"].waitForExistence(timeout: 10))
        shot("02-nota-affiancata")

        app.buttons["Anteprima"].tap()
        shot("03-nota-anteprima")

        app.buttons["Penna"].tap()
        sleep(1)
        shot("04-penna")

        app.buttons["Grafo"].firstMatch.tap()
        // Il layout si calcola in background.
        sleep(4)
        shot("05-grafo")

        let search = app.textFields["Cerca nel grafo"]
        if search.waitForExistence(timeout: 5) {
            search.tap()
            search.typeText("analisi\n")
            sleep(2)
            shot("06-grafo-ricerca")
        } else {
            XCTFail("campo di ricerca del grafo non trovato")
        }

        app.buttons["Importa da Obsidian"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Importa da Obsidian"].waitForExistence(timeout: 5))
        shot("07-import")
    }

    @MainActor
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
