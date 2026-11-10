import XCTest

final class FitheWakeUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [LaunchFlag.keepAwake.argument, LaunchFlag.skipOnboarding.argument] + extra
        app.launch()
        XCTAssertTrue(app.buttons["editAlarm"].waitForExistence(timeout: 10))
        return app
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, swipes: Int = 6) {
        for _ in 0..<swipes {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
    }
    private func attach(_ app: XCUIApplication, _ name: String) {
        let item = XCTAttachment(screenshot: app.screenshot())
        item.name = name; item.lifetime = .keepAlways; add(item)
    }
    private func openDiagnostics(_ app: XCUIApplication) {
        app.buttons["tonightTab"].tap()
        let diagnostics = app.buttons["openDiagnostics"]
        for _ in 0..<3 {
            if !diagnostics.exists { app.buttons["alarmOptions"].tap() }
            if diagnostics.waitForExistence(timeout: 2) {
                diagnostics.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
                if app.navigationBars["Testing"].waitForExistence(timeout: 3) { return }
            }
        }
        XCTFail("Testing sheet did not open")
    }
    /// Read-only design capture: opens screens and cancels; never saves or arms.
    func testCaptureDesignScreens() {
        for hour in ["23", "7"] {
            let app = launch(extra: [LaunchFlag.previewHour.argument(hour), LaunchFlag.previewIntro.argument(1)])
            attach(app, "design-home-\(hour)h")
            app.swipeUp()
            attach(app, "design-home-scrolled-\(hour)h")
            app.swipeDown()
            app.buttons["editAlarm"].tap()
            if app.buttons["armAlarm"].waitForExistence(timeout: 5) { attach(app, "design-editor-\(hour)h") }
            app.buttons["Cancel"].tap()
            _ = app.buttons["editAlarm"].waitForExistence(timeout: 5)
            app.buttons["fitbitTab"].tap()
            sleep(1)
            attach(app, "design-fitbit-\(hour)h")
            app.terminate()
        }
    }
    /// Read-only: the opening ring animation, as held poses, then measured live.
    func testCaptureCrownIntro() {
        for pose in ["0.1", "0.2", "0.32", "0.5", "1"] {
            let app = launch(extra: [LaunchFlag.previewHour.argument(23), LaunchFlag.previewIntro.argument(pose)])
            attach(app, "intro-\(pose)")
            app.terminate()
        }
        let app = launch(extra: [LaunchFlag.previewHour.argument(23), LaunchFlag.introProbe.argument])
        let probe = app.staticTexts["introProbe"]
        let measured = NSPredicate(format: "label BEGINSWITH 'intro'")
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: measured, evaluatedWith: probe)], timeout: 12), .completed)
        let note = XCTAttachment(string: probe.label)
        note.name = "intro-probe"; note.lifetime = .keepAlways; add(note)
        print("INTRO PROBE: \(probe.label)")
        app.terminate()
    }
    /// Read-only: the three onboarding steps. Never sets the alarm, never connects or pauses
    /// the wearable; the app is terminated before the flow finishes.
    func testCaptureOnboarding() {
        let app = XCUIApplication()
        app.launchArguments = [LaunchFlag.keepAwake.argument, LaunchFlag.onboarding.argument, LaunchFlag.previewHour.argument(23), LaunchFlag.previewIntro.argument(1)]
        app.launch()
        let start = app.buttons["onboardingStart"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        sleep(3)
        attach(app, "onboarding-1-welcome")
        start.tap()
        let skip = app.buttons["onboardingSkipAlarm"]
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["onboardingSetAlarm"].exists)
        sleep(2)
        attach(app, "onboarding-2-alarm")
        XCTAssertTrue(app.segmentedControls["onboardingWindow"].isHittable)
        skip.tap()
        XCTAssertTrue(app.buttons["onboardingBack"].waitForExistence(timeout: 5))
        sleep(2)
        attach(app, "onboarding-3-fitbit")
        app.buttons["onboardingBack"].tap()
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        app.terminate()
    }
    private func alarmTime(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any).matching(identifier: "alarmTime").firstMatch.label
    }
    func testMainScreensAndCancelPreservesAlarm() {
        let app = launch()
        let time = alarmTime(app)
        attach(app,"production-home")
        app.buttons["editAlarm"].tap()
        XCTAssertTrue(app.buttons["armAlarm"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["armAlarm"].isHittable)
        attach(app,"production-editor")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["editAlarm"].waitForExistence(timeout: 5))
        XCTAssertEqual(alarmTime(app), time)
        app.buttons["fitbitTab"].tap()
        XCTAssertTrue(app.otherElements["liveHeartRate"].exists || app.staticTexts["liveHeartRate"].exists)
        attach(app,"production-fitbit")
        reveal(app.buttons["toggleMonitoring"], in: app)
        XCTAssertTrue(app.buttons["toggleMonitoring"].isHittable)
        openDiagnostics(app)
        attach(app,"production-diagnostics")
        reveal(app.buttons["prepareReport"], in: app)
        app.buttons["prepareReport"].tap()
        XCTAssertTrue(app.buttons["shareReport"].waitForExistence(timeout: 5))
    }
    func testLargeTextNavigation() {
        let app = launch(extra: [LaunchFlag.largeType.argument])
        attach(app,"production-large-home")
        app.buttons["editAlarm"].tap()
        XCTAssertTrue(app.buttons["armAlarm"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["armAlarm"].isHittable)
        app.buttons["Cancel"].tap()
        app.buttons["fitbitTab"].tap()
        reveal(app.buttons["toggleMonitoring"], in: app)
        XCTAssertTrue(app.buttons["toggleMonitoring"].isHittable)
        attach(app,"production-large-fitbit")
    }
    func testMainAlarmSaveRestoreAndDisarm() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FITHEWAKE_HARDWARE_QA"] == "1")
        let app = launch()
        // Only an empty Tonight screen offers this button; an existing alarm stays untouched.
        try XCTSkipUnless(app.buttons["setWakeTime"].exists, "Preserve an existing user alarm")
        app.buttons["editAlarm"].tap()
        app.buttons["armAlarm"].tap()
        XCTAssertTrue(app.staticTexts["Alarm ready"].waitForExistence(timeout: 10))
        attach(app,"production-alarm-ready")
        let time = alarmTime(app)
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["Alarm ready"].waitForExistence(timeout: 10))
        XCTAssertEqual(alarmTime(app), time)
        app.buttons["turnOffAlarm"].tap()
        app.buttons["Turn off alarm"].tap()
        XCTAssertTrue(app.buttons["setWakeTime"].waitForExistence(timeout: 10))
    }
    func testSeparateNativeAlarmRestoreAndCancel() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FITHEWAKE_HARDWARE_QA"] == "1")
        let app = launch()
        let originalTime = alarmTime(app)
        openDiagnostics(app)
        if app.buttons["cancelTestAlarm"].exists && ProcessInfo.processInfo.environment["FITHEWAKE_CLEAN_PREVIOUS_QA_ALARM"] == "1" {
            app.buttons["cancelTestAlarm"].tap()
            XCTAssertTrue(app.buttons["scheduleTestAlarm"].waitForExistence(timeout: 5))
        }
        try XCTSkipUnless(!app.buttons["cancelTestAlarm"].exists,"Preserve an existing manual test alarm")
        defer {
            if app.buttons["cancelTestAlarm"].exists { app.buttons["cancelTestAlarm"].tap() }
        }
        app.buttons["scheduleTestAlarm"].tap()
        app.buttons["Schedule test alarm"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.firstMatch.waitForExistence(timeout: 2) {
            // The permission alert's second button allows, whatever the device language.
            let allow = springboard.alerts.firstMatch.buttons.element(boundBy: 1)
            if allow.exists { allow.tap() }
        }
        XCTAssertTrue(app.staticTexts["Test alarm ready"].waitForExistence(timeout: 10))
        attach(app,"production-test-alarm-verified")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["editAlarm"].waitForExistence(timeout: 10))
        XCTAssertEqual(alarmTime(app), originalTime)
        openDiagnostics(app)
        XCTAssertTrue(app.staticTexts["Test alarm ready"].waitForExistence(timeout: 5))
        app.buttons["cancelTestAlarm"].tap()
        XCTAssertTrue(app.buttons["scheduleTestAlarm"].waitForExistence(timeout: 5))
    }
    func testFitbitSilentStreamRecovery() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FITHEWAKE_WEARABLE_QA"] == "1")
        let app = launch(extra: [LaunchFlag.silentStreamOnce.argument])
        app.buttons["fitbitTab"].tap()
        let toggle = app.buttons["toggleMonitoring"]
        reveal(toggle, in: app)
        if toggle.label == "Connect wearable" { toggle.tap() }
        let device = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Connect ' AND label CONTAINS[c] 'Air'"))
        if device.firstMatch.waitForExistence(timeout: 3), device.count == 1 { device.firstMatch.tap() }
        // Wait through the injected 25-second outage and actual resubscription.
        let live = app.descendants(matching: .any).matching(identifier: "liveHeartRate").firstMatch
        let predicate = NSPredicate(format: "label CONTAINS 'bpm'")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: live)], timeout: 65), .completed)
        var missing = 0
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 5)
            missing = live.label.contains("bpm") ? 0 : missing+1
            XCTAssertLessThan(missing,7)
        }
        attach(app,"production-live-fitbit")
    }
    func testOvernightHeartRateWarmup() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FITHEWAKE_OVERNIGHT_QA"] == "1")
        let app = launch()
        XCTAssertTrue(app.staticTexts["Alarm ready"].waitForExistence(timeout: 10))
        let status = app.staticTexts["smartWakeStatus"]
        // Any of these means fresh heart rate is reaching the engine (2-hour warm-up first).
        let ready = NSPredicate(format: "label BEGINSWITH 'Learning your sleeping' OR label BEGINSWITH 'Watching your sleep' OR label BEGINSWITH 'Wake window open'")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: status)], timeout: 330), .completed)
        attach(app, "personal-heart-rate-warmup")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 45)
        app.activate()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: status)], timeout: 15), .completed)
        XCTAssertTrue(app.buttons["fitbitStatus"].label.contains("receiving heart rate"))
        attach(app, "personal-heart-rate-after-background")
    }

    func testManualAudibleAlarm() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FITHEWAKE_MANUAL_AUDIO_QA"] == "1")
        let app = launch()
        let original = app.staticTexts["alarmDigits"].label
        openDiagnostics(app)
        try XCTSkipUnless(!app.buttons["cancelTestAlarm"].exists, "Preserve existing test alarm")
        app.buttons["scheduleTestAlarm"].tap()
        app.buttons["Schedule test alarm"].tap()
        XCTAssertTrue(app.staticTexts["Test alarm ready"].waitForExistence(timeout: 10))
        attach(app, "manual-audio-test-armed")
        app.buttons["Done"].tap()
        XCTAssertEqual(app.staticTexts["alarmDigits"].label, original)
        // Intentionally retained for the user to hear while the phone is locked.
    }

}
