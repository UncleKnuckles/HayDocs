import XCTest

/// Runs in the cloud build on the iPhone Duo simulator: imports the sample documents, opens each,
/// draws on a page, exports, searches, and takes screenshots of every step.
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

    private func isReady(_ element: XCUIElement) -> Bool {
        element.exists && element.isHittable
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

    /// Back to the library. On iOS 27 the back button sits in the toolbar column with the id "BackButton".
    private func back() {
        let candidates = [app.buttons["BackButton"], app.navigationBars.buttons["Документы"], app.navigationBars.firstMatch.buttons.element(boundBy: 0)]
        for button in candidates where isReady(button) {
            button.tap()
            break
        }
        if !app.buttons["libraryMenu"].waitForExistence(timeout: 5) {
            XCTFail("library did not come back")
        }
        sleep(1)
    }

    /// Closes a sheet of the app (Done or Close button; a search field may hide them until cancelled)
    /// until `ready`, an element of the screen under the sheet, can be tapped again.
    private func dismissSheet(until ready: XCUIElement) {
        for _ in 0..<5 {
            if isReady(ready) { return }
            let keys = ["Готово", "Done", "Закрыть", "Close", "Отменить", "Cancel"]
            if let button = keys.map({ app.buttons[$0] }).first(where: { isReady($0) }) {
                button.tap()
            } else if app.keyboards.firstMatch.exists {
                app.typeText("\n")
            } else {
                app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.08)).tap()
            }
            sleep(1)
        }
        if !isReady(ready) { XCTFail("sheet did not close") }
    }

    /// The share sheet is a floating card without a Close button: tap outside it, then drag it down.
    private func dismissShareSheet() {
        let window = app.windows.firstMatch
        let reader = app.buttons["moreMenu"]
        for attempt in 0..<5 {
            if isReady(reader) { return }
            let region = app.otherElements["PopoverDismissRegion"]
            if region.exists {
                region.tap()
            } else if attempt < 3 {
                window.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.08)).tap()
            } else {
                window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.47))
                    .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99)))
            }
            sleep(2)
        }
        if !isReady(reader) { XCTFail("share sheet did not close") }
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

        // Word: two pages, drawing, export, menu, two-page spread, search.
        open("Пример Word")
        shot("03-word-page-1")
        app.swipeUp()
        app.swipeUp()
        sleep(1)
        shot("04-word-scrolled")
        app.swipeDown()
        app.swipeDown()
        app.swipeDown()
        sleep(1)

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
        // Wait for the share sheet: the reader's buttons stop being hittable under it.
        let deadline = Date().addingTimeInterval(15)
        while isReady(app.buttons["moreMenu"]) && Date() < deadline { usleep(500_000) }
        sleep(2)
        shot("09-share-sheet")
        dismissShareSheet()

        tap(["moreMenu", "Ещё"])
        sleep(1)
        shot("10-more-menu")
        tap(["О документе"])
        sleep(1)
        shot("11-document-info")
        dismissSheet(until: app.buttons["moreMenu"])

        tap(["moreMenu", "Ещё"])
        tap(["Разворот"])
        sleep(2)
        shot("12-two-pages")
        tap(["moreMenu", "Ещё"])
        tap(["Разворот"])
        sleep(1)

        tap(["moreMenu", "Ещё"])
        tap(["searchButton", "Найти в тексте"])
        let field = app.searchFields.firstMatch
        if field.waitForExistence(timeout: 5) {
            field.tap()
            field.typeText("HayDocs")
            sleep(2)
        } else {
            XCTFail("no search field")
        }
        shot("13-search")
        // Tapping a result closes the search and shows the found text on its page.
        let found = NSPredicate(format: "label BEGINSWITH 'Стр.'")
        let button = app.buttons.matching(found).firstMatch
        let hit = button.waitForExistence(timeout: 5) ? button : app.staticTexts.matching(found).firstMatch
        if hit.exists && hit.isHittable {
            hit.tap()
            sleep(2)
            shot("13b-search-hit")
        }
        dismissSheet(until: app.buttons["moreMenu"])
        back()

        for (index, title) in ["Пример ArmSCII", "Пример ODT", "Пример DOC", "Пример RTF", "Пример TXT", "Пример PDF"].enumerated() {
            open(title)
            shot(String(format: "%02d-%@", 14 + index, title))
            back()
        }

        tap(["libraryMenu"])
        tap(["openFonts", "Шрифты"])
        sleep(2)
        shot("20-fonts")
        dismissSheet(until: app.buttons["libraryMenu"])
        tap(["libraryMenu"])
        tap(["openSettings", "Настройки"])
        sleep(1)
        shot("21-settings")
        dismissSheet(until: app.buttons["libraryMenu"])
        shot("22-library-end")
    }
}
