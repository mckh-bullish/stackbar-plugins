import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol
@testable import Plugin_ScriptCommands

final class ScriptCommandsTests: XCTestCase {
    func testRefreshTimesAreRaycastsAndAtLeastAMinute() {
        XCTAssertEqual(ScriptCommands.refreshTime("5m"), 300)
        XCTAssertEqual(ScriptCommands.refreshTime("1h"), 3600)
        XCTAssertEqual(ScriptCommands.refreshTime("1d"), 86400)
        XCTAssertEqual(ScriptCommands.refreshTime("10s"), 60, "Stackbar looks once a minute")
        XCTAssertNil(ScriptCommands.refreshTime("soon"))
        XCTAssertNil(ScriptCommands.refreshTime("0m"))
    }

    func testInlineScriptsAndAddedFoldersKeepDistinctIDs() {
        let output = """
        ./battery.sh:#!/bin/bash
        ./battery.sh:# @raycast.title Battery
        ./battery.sh:# @raycast.mode inline
        ./battery.sh:# @raycast.refreshTime 5m
        """
        let mine = ScriptCommands.parse(output)
        XCTAssertEqual(mine.first?.mode, .inline)
        XCTAssertEqual(mine.first?.refreshTime, 300)
        XCTAssertEqual(mine.first?.id, "script-battery-sh", "scripts in ~/Script Commands keep their ids")
        let work = ScriptCommands.parse(output, folder: "/Users/me/work/scripts")
        XCTAssertEqual(work.first?.id, "script-scripts-battery-sh")
        XCTAssertEqual(work.first?.folder, "/Users/me/work/scripts")
    }
}
