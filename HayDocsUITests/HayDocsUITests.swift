import XCTest

/// Runs in the cloud build on the iPhone Duo simulator: imports the sample documents, opens each,
/// draws on a page, exports, and takes screenshots of every step.
final class HayDocsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-uitest", "-uitest-reset", "-uitest-dump", "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Taps the first element found by identifier or label.
    @discardableResult
    private func tap(_ keys: [String], timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for key in keys {
                for query in [app.buttons, app.menuItems, app.cells, app.staticTexts, app.switches] {
                    let element = query[key]
                    if element.exists && element.isHittable {
                        element.tap()
                        return true
                    }
                }
            }
            usleep(250_000)
        } while Date() < deadline
        XCTFail("not found: \(keys)")
        return false
    }

    private func waitGone(_ element: XCUIElement, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while element.exists && Date() < deadline { usleep(500_000) }
    }

    private func open(_ title: String) {
        let card = app.buttons["doc-\(title)"]
        if !card.waitForExistence(timeout: 30) {
            XCTFail("no document \(title)")
            return
        }
        card.tap()
        _ = app.buttons["drawToggle"].waitForExistence(timeout: 15)
        sleep(2)
    }

    private func back() {
        let bar = app.navigationBars.firstMatch
        let backButton = bar.buttons["Документы"].exists ? bar.buttons["Документы"] : bar.buttons.element(boundBy: 0)
        if backButton.exists { backButton.tap() }
        sleep(1)
    }

    private func dismissSheet() {
        for key in ["Закрыть", "Close", "Готово", "Done"] where app.buttons[key].exists && app.buttons[key].isHittable {
            app.buttons[key].tap()
            sleep(1)
            return
        }
        let top = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let bottom = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        top.press(forDuration: 0.05, thenDragTo: bottom)
        sleep(1)
    }

    private func stroke(from a: CGVector, to b: CGVector) {
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: a).press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: b))
    }

    func testTour() throws {
        app.launch()
        XCTAssertTrue(app.buttons["addSamples"].waitForExistence(timeout: 30))
        shot("01-library-empty")
        app.buttons["addSamples"].tap()

        let samples = ["Пример ArmSCII", "Пример DOC", "Пример ODT", "Пример PDF", "Пример RTF", "Пример TXT", "Пример Word"]
        for title in samples {
            XCTAssertTrue(app.buttons["doc-\(title)"].waitForExistence(timeout: 240), "imported \(title)")
        }
        waitGone(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Открываю'")).firstMatch, timeout: 120)
        sleep(2)
        shot("02-library")

        // Word: two pages, drawing, export.
        open("Пример Word")
        shot("03-word-page-1")
        app.swipeUp()
        app.swipeUp()
        sleep(1)
        shot("04-word-scrolled")
        app.swipeDown()
        app.swipeDown()
        app.swipeDown()

        tap(["drawToggle"])
        sleep(2)
        shot("05-drawing-tools")
        stroke(from: CGVector(dx: 0.25, dy: 0.40), to: CGVector(dx: 0.75, dy: 0.46))
        stroke(from: CGVector(dx: 0.30, dy: 0.55), to: CGVector(dx: 0.70, dy: 0.50))
        sleep(1)
        shot("06-drawn")
        tap(["doneDrawing", "Готово"])
        sleep(1)
        shot("07-drawing-done")

        tap(["exportMenu", "Поделиться"])
        sleep(1)
        shot("08-export-menu")
        tap(["exportPDFWithDrawings", "PDF с рисунками"])
        sleep(3)
        shot("09-share-sheet")
        dismissSheet()

        tap(["moreMenu", "Ещё"])
        sleep(1)
        shot("10-more-menu")
        tap(["О документе"])
        sleep(1)
        shot("11-document-info")
        dismissSheet()
        back()

        for (index, title) in ["Пример ArmSCII", "Пример ODT", "Пример DOC", "Пример RTF", "Пример TXT", "Пример PDF"].enumerated() {
            open(title)
            shot(String(format: "%02d-%@", 12 + index, title))
            back()
        }

        tap(["libraryMenu"])
        tap(["openFonts", "Шрифты"])
        sleep(2)
        shot("20-fonts")
        dismissSheet()
        tap(["libraryMenu"])
        tap(["openSettings", "Настройки"])
        sleep(1)
        shot("21-settings")
        dismissSheet()

        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        shot("22-library-landscape")
        open("Пример Word")
        shot("23-word-landscape")
        back()
        XCUIDevice.shared.orientation = .portrait
        sleep(1)
    }
}
