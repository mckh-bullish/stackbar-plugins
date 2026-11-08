import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

final class FileSearchTests: XCTestCase {
    func testOpenAndShowInFinderReachTheHost() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("plan-b4.txt")
        try Data("x".utf8).write(to: file)
        let host = Host(self)
        host.system.simulatedFiles = [FoundFile(path: file.path, name: "plan-b4.txt", folder: "~/tmp", lastUsed: Date())]
        let session = try await host.session("FileSearch")
        let opened = try await session.openView("search", query: CommandQuery(text: "plan"))
        let row = try XCTUnwrap(opened.root?.rows.first)
        try await session.event(try XCTUnwrap(row.actions.first { $0.title == "Open" }).id)
        let opening = await waitUntil { host.opened.all.contains { $0.url.hasSuffix("plan-b4.txt") } }
        XCTAssertTrue(opening, "\(host.opened.all)")
        try await session.event(try XCTUnwrap(row.actions.first { $0.title == "Show in Finder" }).id)
        let revealing = await waitUntil { host.opened.all.contains { $0.url.contains(folder.lastPathComponent) && !$0.url.hasSuffix("plan-b4.txt") } }
        XCTAssertTrue(revealing, "\(host.opened.all)")
        await session.stop()
    }

    func testGoingBackOverASearchAnswersFromMemory() async throws {
        let host = Host(self)
        host.system.simulatedFiles = [FoundFile(path: "/Users/you/Documents/Q3 plan.pdf", name: "Q3 plan.pdf", folder: "~/Documents", lastUsed: Date())]
        let session = try await host.session("FileSearch")
        let opened = try await session.openView("search", query: CommandQuery(text: "plan"))
        XCTAssertEqual(opened.root?.rows.map(\.title), ["Q3 plan.pdf"])
        // Spotlight would now find nothing, but a search typed again soon is answered from memory.
        host.system.simulatedFiles = []
        let again = try await session.updateView(opened.session, query: CommandQuery(text: "Plan"))
        XCTAssertEqual(again?.rows.map(\.title), ["Q3 plan.pdf"])
        let other = try await session.updateView(opened.session, query: CommandQuery(text: "invoice"))
        XCTAssertEqual(other?.rows.count, 0, "a new search still asks Spotlight")
        await session.stop()
    }
}
