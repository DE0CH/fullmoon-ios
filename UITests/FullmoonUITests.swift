import XCTest

/// The phone replica: walks every flow on the simulator. `-uitest` makes the app download the model's small files
/// (about 32 MB, in 256 KB ranges one at a time) through the real background downloader instead of the 5 GB weights;
/// MLX doesn't run in the simulator, so a stand-in answers in the chat. Pause, a killed app, the app in the
/// background, resume, the checksum and the chat UI are real.
final class FullmoonUITests: XCTestCase {
    func testEveryFlow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest", "-reset"]
        app.launch()
        shot(app, "welcome")

        app.buttons["getStarted"].tap()
        XCTAssertTrue(app.buttons["download"].waitForExistence(timeout: 10), "no download button")
        shot(app, "download")
        app.buttons["download"].tap()

        // some bytes arrive, then pause
        XCTAssertTrue(wait(60) { self.title(app) == "downloading" && self.received(app) > 0 }, "never started: \(detail(app))")
        shot(app, "downloading")
        app.buttons["pause"].tap()
        XCTAssertTrue(wait(10) { self.title(app) == "paused" }, "pause didn't pause")
        Thread.sleep(forTimeInterval: 1.5)   // a range finishing as pause was tapped still counts
        let pausedAt = received(app)
        Thread.sleep(forTimeInterval: 4)
        XCTAssertEqual(received(app), pausedAt, "kept downloading while paused")
        shot(app, "paused")

        // a killed app comes back paused, where it left off
        app.terminate()
        app.launchArguments = ["-uitest"]
        app.launch()
        XCTAssertTrue(wait(15) { self.title(app) == "paused" }, "relaunch lost the paused download: \(title(app))")
        XCTAssertEqual(received(app), pausedAt, "relaunch lost progress")

        // resume, then leave the app for a while: the background session keeps going
        app.buttons["resume"].tap()
        XCTAssertTrue(wait(30) { self.title(app) == "downloading" }, "resume didn't resume")
        let before = received(app)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 8)
        app.activate()
        XCTAssertTrue(wait(10) { self.received(app) > before || self.title(app) != "downloading" },
                      "no progress in the background: \(detail(app))")
        print("BACKGROUND: \(before) -> \(received(app)) MB (\(title(app)))")

        XCTAssertTrue(wait(300) { self.title(app) == "ready" }, "never finished: \(title(app)) \(detail(app))")
        shot(app, "ready")
        app.buttons["done"].tap()

        // chat
        let field = app.descendants(matching: .any).matching(identifier: "message").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no message field")
        field.tap()
        field.typeText("hello moon")
        app.buttons["send"].tap()
        let answer = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'You asked'")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 30), "no answer")
        shot(app, "chat")
    }

    private func title(_ app: XCUIApplication) -> String {
        let t = app.staticTexts["downloadTitle"]
        return t.exists ? t.label : ""
    }

    private func detail(_ app: XCUIApplication) -> String {
        let t = app.staticTexts["downloadDetail"]
        return t.exists ? t.label : ""
    }

    /// the "X MB of Y MB" figure, in MB
    private func received(_ app: XCUIApplication) -> Double {
        let text = detail(app)
        guard let first = text.components(separatedBy: " of ").first else { return 0 }
        let parts = first.split(separator: " ")
        guard parts.count == 2, let value = Double(parts[0].replacingOccurrences(of: ",", with: "")) else { return 0 }
        switch parts[1] {
        case "KB": return value / 1000
        case "GB": return value * 1000
        case "bytes": return value / 1_000_000
        default: return value
        }
    }

    private func wait(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return condition()
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
