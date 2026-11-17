// SPDX-License-Identifier: Apache-2.0
import XCTest

/// Walks the first run on a fresh simulator (DESIGN 01): Welcome, the Local Network promises, and
/// looking on the Wi‑Fi. Without a server it answers "What do you have at home?" (a Mac desktop and
/// a NAS), checks the recommendation and its guides, then sets up later. With `HOMESPUN_DISCOVER`
/// (comma-separated names) it expects those servers to be found and recommended; with
/// `HOMESPUN_PAIR_LINK` it pairs through the deep link `homespun-server pair` prints, then does the
/// first task: the estimate, backing up the newest, the receipt, and freeing up their space.
/// Screenshots of every page are attached.
final class OnboardingUITests: XCTestCase {
    private var app: XCUIApplication!
    @MainActor private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    @MainActor func testFirstRun() throws {
        let environment = ProcessInfo.processInfo.environment
        let discover = (environment["HOMESPUN_DISCOVER"] ?? "").split(separator: ",").map(String.init)
        let link = environment["HOMESPUN_PAIR_LINK"].flatMap(URL.init(string:))
        app = XCUIApplication()
        // Other Homespun servers on the Mac's network stay out of it: only these are found.
        app.launchEnvironment["HOMESPUN_DISCOVER_ONLY"] = discover.joined(separator: ",")
        app.launchArguments += ["-hideTips"]
        app.launch()

        let find = app.buttons["setup.find"]
        // A token left in the Keychain by an earlier install that still works: Welcome back (6.9).
        let somethingElse = app.buttons["setup.somethingElse"]
        if somethingElse.waitForExistence(timeout: 8) {
            attach("6.9 Welcome back")
            somethingElse.tap()
        }
        XCTAssertTrue(find.waitForExistence(timeout: 15), "no welcome page on first launch")
        XCTAssertTrue(app.buttons["setup.code"].exists && app.buttons["setup.later"].exists, "no way out of Welcome")
        attach("1.1 Welcome")
        find.tap()

        let promises = app.buttons["network.continue"]
        XCTAssertTrue(promises.waitForExistence(timeout: 10), "no Local Network promises")
        attach("1.2 Local Network promises")
        promises.tap()
        allowAlert("Allow")

        // Back goes all the way to Welcome, and finding starts again from there (no promises twice).
        XCTAssertTrue(app.staticTexts["Looking on your Wi‑Fi…"].waitForExistence(timeout: 5) || app.buttons["setup.server"].exists,
                      "not looking")
        goBack()
        XCTAssertTrue(find.waitForExistence(timeout: 5), "Back from Looking didn't reach Welcome")
        attach("Back at Welcome")
        find.tap()
        XCTAssertFalse(promises.waitForExistence(timeout: 2), "the Local Network promises came twice")

        if !discover.isEmpty {
            try recommendFound(discover)
        } else if link == nil {
            try askWhatsAtHome()
        }

        guard let link else {
            if discover.isEmpty { return }
            // Found, but not paired: set up later from the question.
            app.buttons["setup.different"].firstMatch.tap()
            XCTAssertTrue(app.buttons["setup.later"].waitForExistence(timeout: 10))
            app.buttons["setup.later"].tap()
            XCTAssertTrue(app.buttons["connect.open"].waitForExistence(timeout: 15), "no Set Up notice in the Library")
            return
        }
        try pairByLinkAndTryIt(link)
    }

    // MARK: No server: the question

    @MainActor private func askWhatsAtHome() throws {
        XCTAssertTrue(app.staticTexts["Looking on your Wi‑Fi…"].waitForExistence(timeout: 5), "not looking")
        attach("1.4 Looking")
        XCTAssertTrue(app.buttons["setup.server"].waitForExistence(timeout: 10), "no Still looking after 5 s")
        attach("8.1 Still looking")

        let mac = app.buttons["answer.macDesktop"], nas = app.buttons["answer.nas"]
        XCTAssertTrue(mac.waitForExistence(timeout: 15), "the question didn't come after 10 s")
        let next = app.buttons["question.continue"]
        XCTAssertFalse(next.isEnabled, "Continue before anything is chosen")
        attach("3.2 What do you have at home")
        // "None of these" clears the others; any other answer clears it.
        mac.tap()
        app.buttons["answer.none"].tap()
        XCTAssertFalse(mac.isSelected)
        XCTAssertTrue(app.buttons["answer.none"].isSelected)
        next.tap()
        XCTAssertTrue(app.buttons["none.immich"].waitForExistence(timeout: 5), "no honest page for None of these")
        attach("3.7 None of these yet")
        goBack()

        mac.tap()
        nas.tap()
        XCTAssertTrue(mac.isSelected && nas.isSelected && !app.buttons["answer.none"].isSelected)
        attach("3.2 A Mac desktop and a NAS")
        next.tap()

        // A Mac desktop and a NAS: the Mac, with the NAS instead and both later (§6.3).
        XCTAssertTrue(app.staticTexts["We recommend your Mac"].waitForExistence(timeout: 5), "not recommending the Mac")
        XCTAssertTrue(app.buttons["recommend.machine.nas"].exists, "no Use Your NAS Instead")
        XCTAssertTrue(app.buttons["recommend.both"].exists, "no Use Both (Later)")
        attach("3.0 We recommend your Mac")

        app.buttons["recommend.setUp"].tap()
        XCTAssertTrue(app.buttons["guide.send"].waitForExistence(timeout: 5), "no Mac guide")
        attach("3.3 Set up on a Mac")
        app.buttons["guide.terminal"].tap()
        XCTAssertTrue(app.buttons["guide.done"].waitForExistence(timeout: 5))
        attach("3.3 Terminal steps")
        app.buttons["guide.done"].tap()
        XCTAssertTrue(app.staticTexts["Waiting for your Mac"].waitForExistence(timeout: 5), "no waiting page")
        attach("3.4 Waiting for your Mac")
        goBack()
        goBack()
        goBack()

        app.buttons["recommend.machine.nas"].tap()
        let synology = app.buttons["nas.synology"]
        XCTAssertTrue(synology.waitForExistence(timeout: 5), "no NAS brands")
        attach("4.2 Which NAS")
        synology.tap()
        XCTAssertTrue(app.buttons["nas.copy"].waitForExistence(timeout: 5), "no Synology guide")
        attach("4.3 Synology guide")
        app.buttons["nas.copy"].tap()
        XCTAssertTrue(app.staticTexts["Waiting for your NAS"].waitForExistence(timeout: 5))
        attach("4.4 Waiting for the NAS")
        goBack()
        goBack()
        goBack()

        app.buttons["recommend.both"].tap()
        XCTAssertTrue(app.buttons["split.nas"].waitForExistence(timeout: 5), "no split role page")
        attach("4.5 Split role")
        goBack()

        app.buttons["setup.otherWays"].firstMatch.tap()
        XCTAssertTrue(app.buttons["other.address"].waitForExistence(timeout: 5), "no other ways")
        attach("6.2 Connect another way")
        app.buttons["other.address"].tap()
        let address = app.textFields["server.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap()
        address.typeText("192.0.2.1:8787")
        let code = app.textFields["pair.code"]
        code.tap()
        code.typeText("TBTE93N4")
        XCTAssertEqual(code.value as? String, "TBTE-93N4", "the code isn't formatted as it's typed")
        attach("6.4 Address and code")
        goBack()
        goBack()
        goBack()

        XCTAssertTrue(app.buttons["question.notShowing"].waitForExistence(timeout: 5))
        app.buttons["question.notShowing"].tap()
        XCTAssertTrue(app.buttons["setup.lookAgain"].waitForExistence(timeout: 5), "no not-showing-up page")
        attach("3.1 Not showing up")
        goBack()

        // Set Up Later: the Library, unpaired, with its Set Up notice.
        app.buttons["setup.later"].tap()
        XCTAssertTrue(app.hasTab("Library"), "no Library after Set Up Later")
        // With Photos access, the grid has a Set Up notice; without it, the Library asks for access first.
        let notice = app.buttons["connect.open"], askAccess = app.buttons["Allow Access to Photos"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10) || askAccess.exists, "no Set Up notice")
        attach("6.11 Set Up Later")
    }

    // MARK: Servers found

    @MainActor private func recommendFound(_ names: [String]) throws {
        // Looking settles a couple of seconds after the last server answers.
        if app.descendants(matching: .any)["discovered.\(names[0])"].waitForExistence(timeout: 15) {
            // The one the next page recommends is marked in the list as soon as it answers.
            XCTAssertTrue(app.descendants(matching: .any)["discovered.recommended"].waitForExistence(timeout: 10),
                          "no Recommended badge in Found so far")
            attach("1.4 Looking, found")
        }
        let use = app.buttons["found.use"]
        XCTAssertTrue(use.waitForExistence(timeout: 15), "no recommendation among the servers found")
        XCTAssertTrue(names.contains { use.label.contains($0) }, "recommends \(use.label), not one of \(names)")
        attach(names.count == 1 ? "2.5 One server found" : "1.5 Recommendation")
        XCTAssertTrue(app.buttons["setup.different"].exists, "no Set Up a Different Computer")
        use.tap()
        // A Mac with someone logged in asks for Allow; otherwise a code. Going back withdraws the question.
        let outcome = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier IN {'pair.match', 'pair.code'}")).firstMatch
        XCTAssertTrue(outcome.waitForExistence(timeout: 15), "no way to pair")
        if outcome.identifier == "pair.match" {
            attach("1.6 Allow on the Mac")
            app.buttons["pair.useCode"].tap()
        }
        let code = app.textFields["pair.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        attach("2.1 Pair with a code")
        code.typeText("AAAA2222")
        XCTAssertTrue(app.descendants(matching: .any)["pair.error"].waitForExistence(timeout: 15), "no error for a wrong code")
        XCTAssertEqual(code.value as? String, "AAAA-2222", "the code wasn't kept")
        attach("8.4 That code didn't work")
        goBack()
        XCTAssertTrue(use.waitForExistence(timeout: 10))
    }

    // MARK: Pairing link, then the first task

    @MainActor private func pairByLinkAndTryIt(_ link: URL) throws {
        app.open(link)
        let confirm = app.buttons["pair.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "pairing link not handled")
        attach("6.5 Pairing link opened")
        confirm.tap()

        let ready = app.buttons["ready.continue"]
        XCTAssertTrue(ready.waitForExistence(timeout: 60), "no Ready page after pairing")
        attach("1.7 Ready")
        ready.tap()
        // Asked once, before Photos access; Share is the prominent choice, Don't Share sits right under it.
        let share = app.buttons["analytics.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 10), "no analytics question after Ready")
        XCTAssertTrue(app.buttons["analytics.dontShare"].exists)
        attach("1.7a Help improve Homespun")
        // Every setup page can go back: here, to Ready.
        goBack()
        XCTAssertTrue(ready.waitForExistence(timeout: 5), "Back from the analytics question didn't reach Ready")
        ready.tap()
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        share.tap()
        let photos = app.buttons["photos.continue"]
        if photos.waitForExistence(timeout: 3) {
            attach("1.8 Photos promises")
            photos.tap()
            allowAlert("Allow Full Access", timeout: 15)
        }

        // Setup ends in the Library, picking what to try from what isn't backed up.
        let choose = app.buttons["estimate.choose"]
        XCTAssertTrue(choose.waitForExistence(timeout: 60), "no estimate")
        attach("1.10 What you could free up")
        choose.tap()
        // (Select mode hides the tab bar.)
        XCTAssertTrue(app.descendants(matching: .any)["select.done"].waitForExistence(timeout: 15),
                      "setup didn't end in the Library's Select mode")
        let candidates = app.gridItems("Not backed up")
        XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout: 20), "nothing to pick")
        let picked = Array(candidates.allElementsBoundByIndex.filter { app.isOnScreen($0) }.suffix(2))
        for item in picked { item.tap() }
        attach("1.11 Picked")
        let backUp = app.descendants(matching: .any)["compact.selected"]
        XCTAssertTrue(backUp.waitForExistence(timeout: 5), "no Back Up for the picked items")
        backUp.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        // Then Free Up Space, comparing a copy with its original before anything is removed.
        let offer = app.descendants(matching: .any)["offer.free"]
        XCTAssertTrue(offer.waitForExistence(timeout: 600), "the backup didn't finish")
        attach("1.12 Safe on the server")
        offer.tap()
        let compare = app.buttons["remove.compare"].firstMatch
        XCTAssertTrue(compare.waitForExistence(timeout: 10), "no compact copies to compare")
        attach("3.1 Check the copies first")
        compare.tap()
        XCTAssertTrue(app.staticTexts["compare.compact"].waitForExistence(timeout: 30), "no Compare")
        attach("1.13 Compare")
        // Compare opened inside the sheet: Back returns to the review.
        XCTAssertTrue(app.buttons["remove.keepOriginal"].exists, "Compare isn't inside Free Up Space")
        app.goBack(from: "Compare")
        let free = app.buttons["remove.confirm"]
        XCTAssertTrue(free.waitForExistence(timeout: 5))
        XCTAssertTrue(free.label.hasPrefix("They Look Right"), free.label)
        free.tap()
        // The server checks each original again, then iOS asks (the alert may belong to the app or SpringBoard).
        let delete = [app.alerts.buttons["Delete"], springboard.alerts.buttons["Delete"]]
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline, !delete.contains(where: \.exists) { sleep(1) }
        attach(springboard, "1.14 iOS asks")
        guard let button = delete.first(where: \.exists) else { return XCTFail("iOS didn't ask to delete") }
        button.tap()
        XCTAssertTrue(app.staticTexts["remove.summary"].waitForExistence(timeout: 60), "nothing freed")
        attach("1.15 Freed")
        app.buttons["remove.dismiss"].tap()
        XCTAssertTrue(app.isConnected())
        // Their originals are at home now (the Library still shows what isn't backed up; show everything).
        if app.descendants(matching: .any)["select.done"].exists {
            app.descendants(matching: .any)["select.done"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        app.descendants(matching: .any)["grid.filter"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let all = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'All Items'")).firstMatch
        if all.waitForExistence(timeout: 5) { all.tap() }
        attach("1.16 Library")
        XCTAssertTrue(app.gridItems("Original at home").firstMatch.waitForExistence(timeout: 10), "no originals at home")

        // A link to another server (from any app or page) warns before replacing this one.
        if var other = URLComponents(url: link, resolvingAgainstBaseURL: false) {
            other.queryItems = other.queryItems?.map {
                $0.name == "server" ? URLQueryItem(name: "server", value: "192.0.2.1:8787") : $0
            }
            app.open(other.url!)
            XCTAssertTrue(app.descendants(matching: .any)["pair.replaces"].waitForExistence(timeout: 10), "no replace warning")
            XCTAssertTrue(app.buttons["pair.confirm"].label.hasPrefix("Replace"))
            attach("6.5 Replace warning")
            app.buttons["pair.cancel"].tap()
            XCTAssertTrue(app.isConnected(timeout: 10), "pairing changed after cancel")
        }
    }

    // MARK: Helpers

    @MainActor private func goBack() {
        let strip = app.descendants(matching: .any)["BackButton"]
        if strip.waitForExistence(timeout: 2) { return strip.tap() }
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5), "no Back button")
        back.tap()
    }

    /// Taps a system alert's button if one appears.
    @MainActor private func allowAlert(_ title: String, timeout: TimeInterval = 3) {
        let button = springboard.buttons[title].firstMatch
        if button.waitForExistence(timeout: timeout) { button.tap() }
    }

    @MainActor private func attach(_ name: String) { attach(app, name) }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
