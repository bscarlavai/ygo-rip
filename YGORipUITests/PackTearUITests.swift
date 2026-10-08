import XCTest

/// Drives the pack rip with a **real touch sequence**, in both rip styles.
///
/// Ported from poke-rip. The dynamic pack renders into PackTear's `SKView`, so nothing short of
/// real touches reaches `touchesBegan`/`Moved`/`Ended` on this screen.
/// `XCUIElement.press(forDuration:thenDragTo:)` posts genuine touch events.
///
/// The style is forced per test with a `-ripMode <raw>` launch argument: arguments land in
/// UserDefaults' argument domain, which wins over the stored value, so no app code knows about
/// tests and the simulator's own setting is left alone.
final class PackTearUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - Dynamic

    /// A real drag across the pack tears it open and reaches the card.
    func testARealDragTearsThePackOpen() throws {
        let app = launchAtSealedPack(ripMode: "dynamic")
        let hint = app.staticTexts["Drag across the pack to tear it open"]
        try XCTSkipUnless(hint.waitForExistence(timeout: 20), reasonForNoPack(app))
        attachScreenshot(app, "dynamic-sealed")

        drag(across: app, fromX: 0.08, toX: 0.94, atY: 0.32)

        // The reveal replaces the hint, so its disappearance IS the tear committing.
        XCTAssertTrue(hint.waitForNonExistence(timeout: 15), "a full drag across the pack did not open it")
        attachScreenshot(app, "dynamic-after-tear")
    }

    /// A sideways drag across the middle, reaching neither edge, opens the pack (PackTear 1.1.1's
    /// forgiving gesture — the strict one was reported as "hard" and "weird" in poke-rip).
    func testASidewaysDragAcrossTheMiddleOpensThePack() throws {
        let app = launchAtSealedPack(ripMode: "dynamic")
        let hint = app.staticTexts["Drag across the pack to tear it open"]
        try XCTSkipUnless(hint.waitForExistence(timeout: 20), reasonForNoPack(app))

        drag(across: app, fromX: 0.30, toX: 0.62, atY: 0.34)

        XCTAssertTrue(hint.waitForNonExistence(timeout: 8), "a sideways drag across the pack did not open it")
    }

    /// A short scratch does nothing — a stray touch must not cost someone a rip.
    func testAShortScratchDoesNotOpenThePack() throws {
        let app = launchAtSealedPack(ripMode: "dynamic")
        let hint = app.staticTexts["Drag across the pack to tear it open"]
        try XCTSkipUnless(hint.waitForExistence(timeout: 20), reasonForNoPack(app))

        drag(across: app, fromX: 0.45, toX: 0.52, atY: 0.34)

        XCTAssertFalse(hint.waitForNonExistence(timeout: 4), "a scratch that barely moved opened the pack")
    }

    // MARK: - Classic

    /// A swipe anywhere splits the classic pack open.
    func testAClassicSwipeOpensThePack() throws {
        let app = launchAtSealedPack(ripMode: "classic")
        let hint = app.staticTexts["Swipe to rip the pack open"]
        try XCTSkipUnless(hint.waitForExistence(timeout: 20), reasonForNoPack(app))
        attachScreenshot(app, "classic-sealed")

        drag(across: app, fromX: 0.25, toX: 0.80, atY: 0.40)

        XCTAssertTrue(hint.waitForNonExistence(timeout: 8), "a classic swipe did not open the pack")
        attachScreenshot(app, "classic-after-swipe")
    }

    // MARK: - Screens (screenshots for review; no packs spent)

    /// Captures the Settings sections this release changed: rip style, favor level, audio sliders.
    func testCaptureSettings() {
        let app = makeApp()
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Rip Style"].waitForExistence(timeout: 10) || scrollTo(app.staticTexts["Rip Style"], in: app),
                      "no Rip Style setting:\n\(visible(app))")
        attachScreenshot(app, "settings-top")
        _ = scrollTo(app.staticTexts["Favor Unpulled Cards"], in: app)
        attachScreenshot(app, "settings-gameplay")
        _ = scrollTo(app.staticTexts["Background Music"], in: app)
        attachScreenshot(app, "settings-audio")
    }

    /// Captures the Collection controls (view/sort row, filter row with the new set filter).
    func testCaptureCollection() {
        let app = makeApp()
        app.launch()
        app.tabBars.buttons["Collection"].tap()
        _ = app.staticTexts.firstMatch.waitForExistence(timeout: 10)
        attachScreenshot(app, "collection")
    }

    // MARK: - Helpers

    /// The app with its first-run sheets pre-dismissed. On a fresh simulator the onboarding and
    /// cross-promo sheets cover the set tiles, and every pack test fails on navigation.
    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-hasCompletedOnboarding", "YES",
            // Every key in SiblingApp.crossPromoTargets.
            "-crossPromoSeenApps", "(pokerip, mtgrip, onerip)",
        ]
        return app
    }

    /// Home → a set → a sealed pack. Tolerant about the route; fails loudly with what's on screen.
    private func launchAtSealedPack(ripMode: String) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments += ["-ripMode", ripMode]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "the app never came to the foreground")

        // A set tile shows its "<owned>/<total>" counter; nothing else on Home does.
        let setCard = app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".*[0-9]+/[0-9]+.*")).firstMatch
        XCTAssertTrue(setCard.waitForExistence(timeout: 15), "no set to open:\n\(visible(app))")
        setCard.tap()

        let rip = app.buttons["Rip a Pack"]
        if rip.waitForExistence(timeout: 8) {
            rip.tap()
        } else {
            XCTFail("no Rip a Pack button on the set screen:\n\(visible(app))")
        }
        return app
    }

    /// A genuine press-and-drag across the window, in normalised coordinates. Taken off the window
    /// because the pack lives inside an `SKView` with no queryable element of its own. A real
    /// duration, not a flick: the scene samples `touchesMoved`.
    private func drag(across app: XCUIApplication, fromX: Double, toX: Double, atY y: Double) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: fromX, dy: y))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: toX, dy: y))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0)
    }

    @discardableResult
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
        return element.exists
    }

    private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Why there is no sealed pack. Out of free packs, every pack test skips — and xcodebuild still
    /// prints TEST SUCCEEDED for a run where nothing executed, so say so plainly.
    private func reasonForNoPack(_ app: XCUIApplication) -> String {
        if app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH[c] 'Next pack in'")).firstMatch.exists
            || app.buttons["Unlock Unlimited Rips"].exists {
            return "OUT OF FREE PACKS — this run tested nothing. Wait for the timer, then re-run."
        }
        return "never reached a sealed pack — navigation changed:\n\(visible(app))"
    }

    private func visible(_ app: XCUIApplication) -> String {
        let buttons = app.buttons.allElementsBoundByIndex.prefix(12).map { $0.label }
        let texts = app.staticTexts.allElementsBoundByIndex.prefix(12).map { $0.label }
        return "buttons: \(buttons)\ntexts: \(texts)"
    }
}
