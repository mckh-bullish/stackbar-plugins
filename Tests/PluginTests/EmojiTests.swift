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

    func testPlainLettersFindAccentedAndApostropheNames() async throws {
        let host = Host(self)
        let session = try await host.session("Emoji")
        let pinata = try await found(session, "pinata")
        XCTAssertTrue(pinata.contains { $0.title == "🪅" }, "\(pinata.map(\.title))")
        let clock = try await found(session, "oclock")
        XCTAssertTrue(clock.contains { $0.title == "🕐" }, "\(clock.map(\.title))")
        let cote = try await found(session, "cote")
        XCTAssertTrue(cote.contains { $0.subtitle?.contains("Côte") == true }, "\(cote.map(\.subtitle))")
        await session.stop()
    }

    func testPastingAnEmojiFindsIt() async throws {
        let host = Host(self)
        let session = try await host.session("Emoji")
        let pasted = try await found(session, "👍")
        XCTAssertEqual(pasted.first?.title, "👍")
        let toned = try await found(session, "👍🏽")
        XCTAssertEqual(toned.first?.title, "👍", "a toned emoji finds its plain one")
        await session.stop()
    }

    func testSkinToneTonesHumansOnly() async throws {
        let host = Host(self)
        let session = try await host.session("Emoji")
        try await session.event(ActionID("picker/Skin tone"), value: .text("Medium"))
        let thumbs = try await found(session, "thumbs up")
        XCTAssertEqual(thumbs.first?.title, "👍🏽")
        let coder = try await found(session, "technologist")
        XCTAssertTrue(coder.contains { $0.title == "\u{1F9D1}\u{1F3FD}\u{200D}\u{1F4BB}" }, "\(coder.map(\.title))")
        let family = try await found(session, "family man woman girl")
        XCTAssertTrue(family.contains { $0.title == "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}" }, "\(family.map(\.title))")
        let keycap = try await found(session, "keycap 1")
        XCTAssertTrue(keycap.contains { $0.title == "1\u{FE0F}\u{20E3}" }, "\(keycap.map(\.title))")
        let japan = try await found(session, "japan")
        XCTAssertTrue(japan.contains { $0.title == "\u{1F1EF}\u{1F1F5}" }, "\(japan.map(\.title))")
        let family2 = try await found(session, "family")
        XCTAssertTrue(family2.contains { $0.title == "\u{1F46A}" }, "\(family2.map(\.title))")
        let bunny = try await found(session, "people with bunny ears")
        XCTAssertTrue(bunny.contains { $0.title == "\u{1F46F}" }, "\(bunny.map(\.title))")
        await session.stop()
    }

    func testCommonWordsFindTheirEmoji() async throws {
        let host = Host(self)
        let session = try await host.session("Emoji")
        let happy = try await found(session, "happy")
        XCTAssertTrue(happy.contains { $0.title == "😀" })
        let love = try await found(session, "love")
        XCTAssertTrue(love.contains { $0.title == "❤️" }, "\(love.map(\.title))")
        await session.stop()
    }
}
