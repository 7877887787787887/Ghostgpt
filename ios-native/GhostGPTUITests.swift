import XCTest

@MainActor
final class GhostGPTUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "io.corelo.ghostgpt")
        // UserDefaults launch overrides apply only to this simulator process.
        // Never clear app data/Keychain or contact a model/terminal service.
        app.launchArguments = [
            "-modelProvider", "Cloudflare", "-autoStartPCModel", "false",
            "-savedChatsJSON", "[]",
            "-terminalGatewayURL", "http://invalid.invalid/terminal"
        ]
    }

    override func tearDownWithError() throws {
        if testRun?.hasSucceeded == false {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Failure-\(name)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        app.terminate()
    }

    private func launch() {
        app.launch()
        XCTAssertTrue(app.staticTexts["What can I help with?"].waitForExistence(timeout: 45))
    }

    private var composer: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "ghost.chat.composer").firstMatch
    }

    private func selectTab(_ title: String) {
        let bottomTab = app.tabBars.buttons[title]
        // iPhone Duo exposes the system side rail as ordinary buttons, not a
        // TabBar. Match both the title and its icon identifier to distinguish
        // the rail from similarly named links inside Settings or Tools.
        let icons = ["Chat": "bubble.left.and.bubble.right.fill", "Browser": "globe",
                     "Tools": "terminal", "Settings": "gearshape"]
        guard let icon = icons[title] else { XCTFail("Unknown tab: \(title)"); return }
        let tab = bottomTab.exists ? bottomTab : app.buttons.matching(
            NSPredicate(format: "label == %@ AND identifier == %@", title, icon)
        ).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "Missing tab: \(title)")
        tab.tap()
    }

    func testSettingsBrowserAndToolsNavigation() {
        launch()
        selectTab("Settings")
        XCTAssertTrue(app.staticTexts["Native SwiftUI interface"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches["Notifications"].exists)
        XCTAssertTrue(app.buttons["AI models and local model scan"].exists)

        selectTab("Browser")
        XCTAssertTrue(app.textFields["Search or enter URL"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Copy URL"].exists)

        selectTab("Tools")
        XCTAssertTrue(app.buttons["PowerShell terminal"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Linux sandbox / SSH"].exists)
        selectTab("Chat")
        XCTAssertTrue(app.staticTexts["What can I help with?"].waitForExistence(timeout: 10))
    }

    func testEmptyAndWhitespaceMessagesCannotSend() {
        launch()
        let send = app.buttons["ghost.chat.send"]
        XCTAssertTrue(send.exists)
        XCTAssertFalse(send.isEnabled)
        composer.tap()
        composer.typeText("   ")
        XCTAssertFalse(send.isEnabled, "Whitespace must not trigger a network request")
    }

    func testQuickPromptFillsDraftWithoutSending() {
        launch()
        app.buttons["ghost.quick-prompt.Write code"].tap()
        let value = composer.value as? String ?? ""
        XCTAssertTrue(value.contains("Help me write and debug code"), value)
        XCTAssertTrue(app.buttons["ghost.chat.send"].isEnabled)
        XCTAssertTrue(app.staticTexts["What can I help with?"].exists)
    }

    func testClosingHistoryPreservesUnsentDraft() {
        launch()
        let draft = "Keep this unsent draft"
        composer.tap()
        composer.typeText(draft)
        app.buttons["Chat history and navigation"].tap()
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["New chat"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertEqual(composer.value as? String, draft)
    }

    func testInsecureTerminalURLIsRejectedWithoutExecuting() {
        launch()
        selectTab("Tools")
        app.buttons["PowerShell terminal"].tap()
        let status = app.staticTexts["ghost.terminal.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let rejected = expectation(for: NSPredicate(
            format: "label CONTAINS %@", "Configure a valid HTTPS gateway URL"
        ), evaluatedWith: status)
        wait(for: [rejected], timeout: 10)
        XCTAssertFalse(app.buttons["Run reviewed command"].isEnabled)
    }
}
