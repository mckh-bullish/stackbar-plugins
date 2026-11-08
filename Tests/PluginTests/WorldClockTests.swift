import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

final class WorldClockTests: XCTestCase {
    private let addField: ActionID = "field/Add a city or time zone, like Tokyo"

    func testFindsCitiesByTheirCommonNames() async throws {
        let host = Host(self)
        let session = try await host.session("WorldClock")
        let expected: [(query: String, zone: String)] = [
            ("time in mumbai", "Asia/Kolkata"),
            ("san francisco", "America/Los_Angeles"),
            ("time in nyc", "America/New_York"),
            ("bangalore time", "Asia/Kolkata"),
            ("time in são paulo", "America/Sao_Paulo"),
            ("time in pst", "America/Los_Angeles"),
            ("beijing", "Asia/Shanghai"),
            ("tokyo?", "Asia/Tokyo"),
        ]
        for (query, zone) in expected {
            let opened = try await session.openView("time-in", query: CommandQuery(text: query))
            XCTAssertEqual(opened.root?.rows.first?.key, zone, query)
        }
        for query in ["sf", "eat", "hello"] {
            let opened = try await session.openView("time-in", query: CommandQuery(text: query))
            XCTAssertEqual(opened.root?.rows.count ?? 0, 0, "\(query) is not a city")
        }
        await session.stop()
    }

    func testAddsACityByItsCommonName() async throws {
        let host = Host(self)
        let supervisor = try await host.start("WorldClock")

        // Kolkata is a starting city, and Mumbai is in that zone, so it's refused until Kolkata goes.
        await supervisor.press(addField, value: .text("Mumbai"))
        var settings = await supervisor.views[.settings].map { TreeTextRenderer.render($0) } ?? ""
        XCTAssertTrue(settings.contains("Kolkata is already in your list"), settings)

        await supervisor.press("row/zone-Asia/Kolkata/Remove")
        await supervisor.press(addField, value: .text("Mumbai"))
        let times = await supervisor.callTool("times").text
        XCTAssertTrue(times.contains("Mumbai: "), times)

        await supervisor.press(addField, value: .text("Atlantis"))
        settings = await supervisor.views[.settings].map { TreeTextRenderer.render($0) } ?? ""
        XCTAssertTrue(settings.contains("No city or time zone called “Atlantis”"), settings)
        let unchanged = await supervisor.callTool("times").text
        XCTAssertEqual(unchanged, times, "a city that isn't found changes nothing")
        await supervisor.stop()
    }

    func testRemovingTheMenuBarCityMovesTheMenuBar() async throws {
        let host = Host(self)
        let supervisor = try await host.start("WorldClock")
        let before = await supervisor.views[.menuBar].map { TreeTextRenderer.render($0) } ?? ""
        XCTAssertTrue(before.contains("London"), before)

        await supervisor.press("row/zone-Europe/London/Remove")
        let bar = await supervisor.views[.menuBar].map { TreeTextRenderer.render($0) } ?? ""
        XCTAssertFalse(bar.contains("London"), bar)
        XCTAssertTrue(bar.contains("Los Angeles"), "the next city takes the menu bar: \(bar)")
        await supervisor.stop()
    }

    func testCopiesEveryCitysTime() async throws {
        let host = Host(self)
        let session = try await host.session("WorldClock")
        guard case .copy(let text) = try await session.runCommand("copy-times") else {
            return XCTFail("copy-times copies the times")
        }
        XCTAssertTrue(text.contains("London") && text.contains("here"), text)
        await session.stop()
    }

    func testAWholeNameRanksAheadOfCitiesThatStartWithIt() async throws {
        let host = Host(self)
        // Your own cities usually come first; these are ones that only start with what's typed.
        try await host.services.storage.set("zones", #"["Europe/Istanbul","America/La_Paz"]"#, for: "io.navbytes.stackbar.plugins.world-clock")
        let session = try await host.session("WorldClock")
        for (query, zone) in [("time in ist", "Asia/Kolkata"), ("time in la", "America/Los_Angeles"), ("what’s the time in tokyo", "Asia/Tokyo")] {
            let opened = try await session.openView("time-in", query: CommandQuery(text: query))
            XCTAssertEqual(opened.root?.rows.first?.key, zone, query)
        }
        await session.stop()
    }

    func testAMenuBarCityThisMacDoesNotKnowFallsBackToTheFirstCity() async throws {
        let host = Host(self)
        let id = "io.navbytes.stackbar.plugins.world-clock"
        try await host.services.storage.set("zones", #"["Mars/Olympus_Mons","Asia/Tokyo"]"#, for: id)
        try await host.services.storage.set("menuBarZone", #""Mars/Olympus_Mons""#, for: id)
        let supervisor = try await host.start("WorldClock")
        let bar = await supervisor.views[.menuBar].map { TreeTextRenderer.render($0) } ?? ""
        XCTAssertTrue(bar.contains("Tokyo"), "the first city this Mac knows takes the menu bar: \(bar)")
        await supervisor.stop()
    }

    /// The clocks anywhere in a tree, as (pattern, zone).
    private func clocks(_ node: ViewNode?) -> [(pattern: String, zone: String?)] {
        guard let node else { return [] }
        if case .clock(let face) = node { return [(face.pattern, face.timeZone)] }
        return node.children.flatMap(clocks)
    }

    func testTheMenuBarIsAClockTheHostKeepsCurrent() async throws {
        let host = Host(self)
        let supervisor = try await host.start("WorldClock")
        let bar = await supervisor.views[.menuBar]
        XCTAssertEqual(clocks(bar).first?.zone, "Europe/London")
        XCTAssertEqual(clocks(bar).first?.pattern, "HH:mm")
        XCTAssertTrue(bar.map { TreeTextRenderer.render($0) }?.contains("London") == true)
        await supervisor.stop()
    }

    func testThisMacsOwnTimeWithTheDateLikeTheMacOSClock() async throws {
        let host = Host(self)
        let id = "io.navbytes.stackbar.plugins.world-clock"
        try await host.services.storage.set("menuBarZone", #""here""#, for: id)
        try await host.services.storage.set("showDate", "true", for: id)
        try await host.services.storage.set("showWeekday", "true", for: id)
        try await host.services.storage.set("showSeconds", "true", for: id)
        try await host.services.storage.set("showIcon", "false", for: id)
        let supervisor = try await host.start("WorldClock")
        let bar = await supervisor.views[.menuBar]
        let clock = try XCTUnwrap(clocks(bar).first)
        XCTAssertNil(clock.zone, "this Mac's time follows the Mac")
        for field in ["EEE", "d", "MMM", "HH", "mm", "ss"] { XCTAssertTrue(clock.pattern.contains(field), clock.pattern) }
        let text = bar.map { TreeTextRenderer.render($0) } ?? ""
        XCTAssertFalse(text.contains("London") || text.contains("globe"), "no city and no icon: \(text)")

        try await host.services.storage.set("menuBarFormat", #""yyyy-MM-dd HH:mm""#, for: id)
        let custom = try await host.start("WorldClock")
        let customBar = await custom.views[.menuBar]
        XCTAssertEqual(clocks(customBar).first?.pattern, "yyyy-MM-dd HH:mm", "a custom format wins")
        await supervisor.stop()
        await custom.stop()
    }

    func testTheTimeTravelSliderFollowsTheThumb() async throws {
        let host = Host(self)
        let supervisor = try await host.start("WorldClock")
        let panel = await supervisor.views[.panel].map { TreeTextRenderer.render($0) } ?? ""
        XCTAssertTrue(panel.contains("(-12...12) live"), panel)
        await supervisor.press("slider/time-travel", value: .number(2.5))
        let moved = await supervisor.views[.panel].map { TreeTextRenderer.render($0) } ?? ""
        XCTAssertTrue(moved.contains("+2h 30m from now"), moved)
        await supervisor.stop()
    }
}
