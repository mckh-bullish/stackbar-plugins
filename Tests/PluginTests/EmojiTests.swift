import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

final class EmojiTests: XCTestCase {
    private func found(_ session: PluginSession, _ text: String) async throws -> [RowNode] {
        try await session.openView("search", query: CommandQuery(text: text)).root?.rows ?? []
    }

    func testWordsMatchTheStartOfNameWords() async throws {
        let host = Host(self)
        let session = try await host.session("Emoji")
        let thumbs = try await found(session, "thu up")
        XCTAssertTrue(thumbs.contains { $0.title == "👍" }, "every word starts a word of the name")
        let party = try await found(session, "party")
        XCTAssertTrue(party.contains { $0.title == "🎉" })
        await session.stop()
    }

    func testAHyphenatedQueryMatchesHyphenatedNames() async throws {
        let host = Host(self)
        let session = try await host.session("Emoji")
        let fist = try await found(session, "left-facing")
        XCTAssertTrue(fist.contains { $0.title == "🤛" }, "\(fist.map(\.title))")
        let eyes = try await found(session, "heart-eyes")
        XCTAssertTrue(eyes.contains { $0.title == "😍" })
        let upside = try await found(session, "upside-down")
        XCTAssertTrue(upside.contains { $0.title == "🙃" })
        await session.stop()
    }

    func testOnlySeparatorsMatchNothingInsteadOfEverything() async throws {
        let host = Host(self)
        let session = try await host.session("Emoji")
        for text in [":", "::", "-", ": -"] {
            let rows = try await found(session, text)
            XCTAssertTrue(rows.isEmpty, "\"\(text)\" is not a search: \(rows.count) rows")
        }
        let all = try await found(session, "")
        XCTAssertGreaterThan(all.count, 1000, "nothing typed still browses everything")
        await session.stop()
    }
}
