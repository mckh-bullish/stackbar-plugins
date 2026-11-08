import Foundation
import XCTest
@testable import Plugin_BrowserTabs

final class BrowserTabsTests: XCTestCase {
    /// Inside `tell application`, `tab` is the browser's tab class, so the
    /// separators must be made before it.
    @MainActor func testTheListScriptMakesItsSeparatorsOutsideTheTell() async {
        for browser in BrowserTabs.browsers {
            let script = BrowserTabs.listScript(browser)
            let inside = script.components(separatedBy: "tell application").dropFirst().joined()
            XCTAssertFalse(inside.contains("& tab &"), "\(browser.name): a bare tab inside the tell joins as the word \"tab\"")
            XCTAssertTrue(script.hasPrefix("set sep to character id 9"), browser.name)
        }
    }

    @MainActor func testParseTabsReadsEachLine() async {
        let text = "1\t1\tStackbar\thttps://stackbar.app\n1\t2\tA\ttitle\twith tabs\thttps://example.com\n2\t1\tmissing value\thttps://x.dev\n"
        let tabs = BrowserTabs.parseTabs(text, browser: "Safari")
        XCTAssertEqual(tabs.map(\.title), ["Stackbar", "A\ttitle\twith tabs", "https://x.dev"])
        XCTAssertEqual(tabs.map(\.window), [1, 1, 2])
        XCTAssertEqual(tabs.map(\.index), [1, 2, 1])
    }

    @MainActor func testParseTabsSkipsLinesThatDidNotSplit() async {
        // What the old script printed: the word "tab" where a tab belonged.
        XCTAssertTrue(BrowserTabs.parseTabs("1tab1tabStackbartabhttps://stackbar.app\n", browser: "Safari").isEmpty)
    }
}
