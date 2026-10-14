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

        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Allegati'")).firstMatch.tap()
        let pdf = app.staticTexts["Dispensa derivate.pdf"]
        if pdf.waitForExistence(timeout: 5) {
            shot("05-allegati")
            pdf.tap()
            sleep(2)
            shot("06-pdf")
            app.buttons["Fine"].firstMatch.tap()
            sleep(1)
        } else {
            XCTFail("allegato dimostrativo non trovato")
        }
        app.buttons["Fine"].firstMatch.tap()

        // Chat del nodo, con un modello dimostrativo al posto di Gemini.
        app.buttons["Chiedi"].firstMatch.tap()
        let input = app.textFields["chat-input"]
        if input.waitForExistence(timeout: 5) {
            input.tap()
            input.typeText("Come si calcola la derivata?")
            app.buttons["Invia"].firstMatch.tap()
            XCTAssertTrue(app.staticTexts["Gemini"].waitForExistence(timeout: 15), "risposta dimostrativa")
            shot("06b-chat")
            app.buttons["Chat"].firstMatch.tap()
            sleep(1)
        } else {
            XCTFail("chat non aperta")
        }

        app.buttons["Grafo"].firstMatch.tap()
        // Il layout si calcola in background.
        sleep(4)
        shot("07-grafo")

        let search = app.textFields["Cerca nel grafo"]
        if search.waitForExistence(timeout: 5) {
            search.tap()
            search.typeText("analisi\n")
            sleep(2)
            shot("08-grafo-ricerca")
        } else {
            XCTFail("campo di ricerca del grafo non trovato")
        }

        app.buttons["Importa"].firstMatch.tap()
        app.buttons["Vault Obsidian"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Importa da Obsidian"].waitForExistence(timeout: 5))
        shot("09-import")
    }

    @MainActor
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
