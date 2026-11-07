import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

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
}
