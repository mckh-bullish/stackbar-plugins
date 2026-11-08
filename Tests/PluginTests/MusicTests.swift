import Foundation
import XCTest
@testable import Plugin_Music

@MainActor
final class MusicTests: XCTestCase {
    /// One status record: the fields joined the way the status script joins them.
    private func record(_ fields: [String], newline: Bool = true) -> String {
        fields.joined(separator: "\u{1F}") + (newline ? "\n" : "")
    }

    func testNineFieldsJoinedByTheUnitSeparatorParse() async {
        let tracks = Music.parse(record(["Spotify", "playing", "Harbor Lights", "Juniper Vale", "Slow Tides", "248", "97", "60", "https://i.scdn.co/image/abc"]))
        XCTAssertEqual(tracks, [Music.Track(player: .spotify, playing: true, name: "Harbor Lights", artist: "Juniper Vale", album: "Slow Tides", duration: 248, position: 97, volume: 60, artworkURL: "https://i.scdn.co/image/abc")])
    }

    func testALineBreakOrTabInATitleBecomesASpace() async {
        let tracks = Music.parse(record(["Music", "paused", "Line one\nLine two\tthree", "Artist", "Album", "180", "10", "50", ""]))
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.name, "Line one Line two three")
        let crlf = Music.parse(record(["Music", "paused", "One\r\nTwo", "Artist", "Album", "1", "0", "50", ""]))
        XCTAssertEqual(crlf.first?.name, "One Two", "a CRLF is one space, not two")
    }

    func testMissingValueBecomesEmptyAndKeepsTheFieldCount() async {
        let tracks = Music.parse(record(["Spotify", "paused", "Stream", "missing value", "missing value", "missing value", "0", "30", "missing value"]))
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.artist, "")
        XCTAssertEqual(tracks.first?.album, "")
        XCTAssertEqual(tracks.first?.duration, 0)
        XCTAssertNil(tracks.first?.artworkURL)
    }

    func testATrailingNewlineIsIgnored() async {
        let fields = ["Music", "playing", "A", "B", "C", "1", "2", "3", ""]
        XCTAssertEqual(Music.parse(record(fields)), Music.parse(record(fields, newline: false)))
        XCTAssertEqual(Music.parse(record(fields)).count, 1)
    }

    func testFewerThanEightFieldsGivesNoTrack() async {
        XCTAssertEqual(Music.parse(record(["Music", "playing", "A", "B", "C", "1", "2"])), [])
        XCTAssertEqual(Music.parse(""), [])
    }
}
