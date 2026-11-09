import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol
@testable import Plugin_Calculator

final class CalculatorTests: XCTestCase {
    /// The answer row's title for what was typed, or nil when there is no answer.
    private func answer(_ session: PluginSession, _ text: String) async throws -> String? {
        let opened = try await session.openView("calculate", query: CommandQuery(text: text))
        return opened.root?.rows.first { $0.title.hasPrefix(text) }?.title
    }

    func testSumsAndUnits() async throws {
        let host = Host(self)
        let session = try await host.session("Calculator")
        let sum = try await answer(session, "12*(3+4)")
        XCTAssertEqual(sum, "12*(3+4) = 84")
        let units = try await answer(session, "3h in min")
        XCTAssertEqual(units, "3h in min = 180 min")
        let height = try await answer(session, "5 ft 10 in to cm")
        XCTAssertEqual(height, "5 ft 10 in to cm = 177.8 cm")
        let meeting = try await answer(session, "1h 30min in min")
        XCTAssertEqual(meeting, "1h 30min in min = 90 min")
        let mixed = try await answer(session, "5 ft 10 kg to cm")
        XCTAssertNil(mixed, "a part of another kind is no answer")
        let word = try await answer(session, "hello")
        XCTAssertNil(word, "words get no answer")
        await session.stop()
    }

    /// Run on a machine whose decimal mark is the point; a comma-decimal Mac
    /// reads `1,000` as one, by design.
    func testACommaIsADecimalMarkUnlessItCanBeAThousandsSeparator() async throws {
        let host = Host(self)
        let session = try await host.session("Calculator")
        let cases: [(String, String?)] = [
            ("2,5*2", "5"),
            ("0,5+0,25", "0.75"),
            ("1,25*4", "5"),
            ("0,500*2", "1"),
            ("1,000+1", "1001"),
            ("2,500,000/2", "1250000"),
            ("1,234.56*2", "2469.12"),
            ("1.234,56+1", "1235.56"),
            ("1,2,3+1", nil),
            ("1,00,000+1", "100001"),
            ("12,34,567*2", "2469134"),
            ("1,00,00+1", nil),
            ("12,34,56+1", nil),
            ("1+.", nil),
            (".", nil),
        ]
        for (text, expected) in cases {
            let title = try await answer(session, text)
            XCTAssertEqual(title, expected.map { "\(text) = \($0)" }, text)
        }
        let km = try await answer(session, "1,5 km in m")
        XCTAssertEqual(km, "1,5 km in m = 1500 m")
        await session.stop()
    }

    func testTimeZones() async throws {
        let host = Host(self)
        let session = try await host.session("Calculator")
        let tokyo = try await answer(session, "9:00 am utc in tokyo")
        XCTAssertEqual(tokyo, "9:00 am utc in tokyo = 6:00 PM in Tokyo")
        await session.stop()
    }

    func testAddingAPercentAddsThatShare() async throws {
        let host = Host(self)
        let session = try await host.session("Calculator")
        let cases: [(String, String)] = [
            ("100 + 10%", "100 + 10% = 110"),
            ("200 - 15%", "200 - 15% = 170"),
            ("15% * 80", "15% * 80 = 12"),
            ("15%", "15% = 0.15"),
            ("200 + 100 * 10%", "200 + 100 * 10% = 210"),
            ("10% + 5%", "10% + 5% = 0.15"),
        ]
        for (text, expected) in cases {
            let title = try await answer(session, text)
            XCTAssertEqual(title, expected, text)
        }
        await session.stop()
    }

    func testSpeedAndE() async throws {
        let host = Host(self)
        let session = try await host.session("Calculator")
        let speed = try await answer(session, "60 mph in km/h")
        XCTAssertEqual(speed, "60 mph in km/h = 96.56064 km/h")
        let e = try await answer(session, "2*e")
        XCTAssertEqual(e, "2*e = 5.436563657")
        await session.stop()
    }

    func testAccentedCities() async throws {
        let host = Host(self)
        let session = try await host.session("Calculator")
        let title = try await answer(session, "9:00 am utc in são paulo")
        XCTAssertTrue(title?.hasPrefix("9:00 am utc in são paulo = 6:00 AM in") == true, "\(title ?? "nil")")
        await session.stop()
    }

    func testNoPasteAction() async throws {
        let host = Host(self)
        let session = try await host.session("Calculator")
        let opened = try await session.openView("calculate", query: CommandQuery(text: "2+2"))
        let row = try XCTUnwrap(opened.root?.rows.first { $0.title.hasPrefix("2+2") })
        XCTAssertEqual(row.actions.map(\.title), ["Copy Answer"], "Calculator has no clipboard access, so there is no paste")
        await session.stop()
    }

    func testDivisionByZeroHasNoAnswerRow() async throws {
        let host = Host(self)
        let session = try await host.session("Calculator")
        let none = try await answer(session, "1/0")
        XCTAssertNil(none)
        await session.stop()
    }

    func testRecentAnswersListWhenNothingIsTyped() async throws {
        let host = Host(self)
        let session = try await host.session("Calculator")
        let opened = try await session.openView("calculate", query: CommandQuery(text: "2+2"))
        let row = try XCTUnwrap(opened.root?.rows.first { $0.title.hasPrefix("2+2") })
        try await session.event(try XCTUnwrap(row.actions.first).id)
        XCTAssertEqual(host.copies.all, ["4"])
        let empty = try await session.openView("calculate", query: CommandQuery(text: ""))
        XCTAssertEqual(empty.root?.rows.first?.title, "4")
        await session.stop()
    }

    func testDecimalCommaFollowsTheSettingExceptInExponentForm() {
        XCTAssertEqual(Calculator.Math.format(7.5, decimalComma: true), "7,5")
        XCTAssertEqual(Calculator.Math.format(7.5, decimalComma: false), "7.5")
        XCTAssertEqual(Calculator.Math.format(1.5e20, decimalComma: true), "1.5e+20")
    }

    func testDateMath() {
        let utc = TimeZone(identifier: "UTC")!
        // Monday, 9 November 2026, mid-afternoon.
        let now = ISO8601DateFormatter().date(from: "2026-11-09T15:00:00Z")!
        func answer(_ text: String) -> String? { Calculator.Math.answer(text, now: now, here: utc)?.display }
        XCTAssertEqual(answer("days until dec 20"), "41 days")
        XCTAssertEqual(answer("days until christmas"), "46 days")
        XCTAssertEqual(answer("weeks until christmas"), "6 weeks")
        XCTAssertEqual(answer("days until jan 1"), "53 days", "a date already past this year is next year's")
        XCTAssertEqual(answer("days since 2026-01-01"), "312 days")
        XCTAssertEqual(answer("days since nov 1"), "8 days")
        XCTAssertEqual(answer("days until tomorrow"), "1 day")
        XCTAssertEqual(answer("today + 3 weeks"), "Mon, 30 Nov 2026")
        XCTAssertEqual(answer("in 10 days"), "Thu, 19 Nov 2026")
        XCTAssertEqual(answer("friday - 2 days"), "Wed, 11 Nov 2026")
        XCTAssertEqual(answer("dec 20 + 1 month"), "Wed, 20 Jan 2027")
        XCTAssertNil(answer("days until someday"))
        XCTAssertNil(answer("in the morning"))
        XCTAssertEqual(answer("5pm london in tokyo")?.hasSuffix("Tokyo"), true, "time zones still win")
    }
}
