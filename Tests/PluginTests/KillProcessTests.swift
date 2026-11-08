import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol
@testable import Plugin_KillProcess

/// The parsing tests call the plugin's functions directly and run anywhere.
/// The rest drive the plugin as a process on this Mac, and only ever signal a
/// `sleep` the test starts itself.
final class KillProcessTests: XCTestCase {
    // MARK: Parsing

    @MainActor func testShortCommandDropsTheProgramPath() async {
        XCTAssertEqual(KillProcess.shortCommand("node", "/usr/local/bin/node server.js"), "node server.js")
        XCTAssertEqual(KillProcess.shortCommand("sleep", "/bin/sleep 31337"), "sleep 31337")
    }

    @MainActor func testShortCommandCutsAtTheLastProgramPath() async {
        // The directory has a space and the name in it; the program is the last one.
        XCTAssertEqual(KillProcess.shortCommand("node", "/Users/me/node projects/x/node server.js"), "node server.js")
    }

    @MainActor func testShortCommandKeepsAHelpersArguments() async {
        let line = "/Applications/Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper --type=renderer"
        XCTAssertEqual(KillProcess.shortCommand("Code Helper", line), "Code Helper --type=renderer")
    }

    @MainActor func testShortCommandLeavesABareCommandAndNoArgumentsAlone() async {
        XCTAssertEqual(KillProcess.shortCommand("node", "node server.js"), "node server.js")
        XCTAssertEqual(KillProcess.shortCommand("node", ""), "", "with no arguments the row shows the pid instead")
    }

    @MainActor func testShortCommandCapsAboutSixtyCharacters() async {
        let short = KillProcess.shortCommand("node", String(repeating: "x", count: 200))
        XCTAssertEqual(short.count, 60)
        XCTAssertTrue(short.hasSuffix("…"))
    }

    @MainActor func testParseArgsReadsEachPidsLine() async {
        let output = "  48211 node server.js\n     77 /bin/sleep 31337\n"
        XCTAssertEqual(KillProcess.parseArgs(output, names: [48211: "node", 77: "sleep"]), [48211: "node server.js", 77: "/bin/sleep 31337"])
    }

    @MainActor func testParseArgsIsEmptyWithoutLinesOrWithoutArguments() async {
        XCTAssertEqual(KillProcess.parseArgs("", names: [1: "a"]), [:])
        XCTAssertEqual(KillProcess.parseArgs("  555\n", names: [555: "a"]), [:], "a pid with no arguments has no entry")
    }

    @MainActor func testParseArgsKeepsTheFirstLineOfAMultilineArgument() async {
        // An argument with a newline in it comes out as two lines; the second has no pid.
        XCTAssertEqual(KillProcess.parseArgs("  100 node -e 'a\nb'\n", names: [100: "node"]), [100: "node -e 'a"])
    }

    @MainActor func testParseArgsIgnoresAPidWhoseCommandNoLongerHasItsName() async {
        // Pid 10 was node when it was listed; by the second call it is something else.
        XCTAssertEqual(KillProcess.parseArgs("  10 sleep 31337\n", names: [10: "node"]), [:])
    }

    @MainActor func testParseArgsKeepsTheFirstLineForAPid() async {
        XCTAssertEqual(KillProcess.parseArgs("  10 node a\n  10 node b\n", names: [10: "node"]), [10: "node a"])
    }

    @MainActor func testParseNeverListsProtectedProcessesOrThisOne() async {
        let own = Int(ProcessInfo.processInfo.processIdentifier)
        let output = "  1 0.0 100 launchd\n  2 0.0 100 Dock\n  3 1.5 2000 node\n  \(own) 0.1 300 xctest\n"
        XCTAssertEqual(KillProcess.parse(output).map(\.name), ["node"])
    }

    #if os(macOS)
    // MARK: Processes

    /// A `sleep` this test starts itself: the only process it may end.
    private func startSleep() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["31337"]
        try process.run()
        return process
    }

    /// The rows the open view shows now.
    private func rows(_ session: PluginSession, _ view: Int) async -> [RowNode] {
        await session.commandView(view)?.rows ?? []
    }

    func testQuitTakesTwoPressesWithinTenSeconds() async throws {
        let sleeper = try startSleep()
        defer { if sleeper.isRunning { sleeper.terminate() } }
        let pid = Int(sleeper.processIdentifier)
        let host = Host(self)
        let session = try await host.session("KillProcess")
        defer { Task { await session.stop() } }
        let opened = try await session.openView("search", query: CommandQuery(text: "sleep 31337"))
        let found = try XCTUnwrap(opened.root?.rows.first { $0.key == "\(pid)" }, "the test's sleep is listed")
        let quit = try XCTUnwrap(found.actions.first { $0.title == "Quit Process" })
        XCTAssertEqual(quit.role, .critical)

        try await session.event(quit.id)
        XCTAssertTrue(sleeper.isRunning, "the first press only asks again")
        let asked = await rows(session, opened.session).first { $0.key == "\(pid)" }
        XCTAssertEqual(asked?.subtitle, "Press again to quit sleep")

        // Past the ten seconds, the first press has lapsed, so the next one asks again.
        try await Task.sleep(for: .seconds(10.5))
        try await session.event(quit.id)
        XCTAssertTrue(sleeper.isRunning, "a press after the window asks again")

        try await session.event(quit.id)
        let ended = await waitUntil(5) { !sleeper.isRunning }
        XCTAssertTrue(ended, "a second press within the window ends it")
        let remaining = await rows(session, opened.session)
        XCTAssertFalse(remaining.contains { $0.key == "\(pid)" }, "and it leaves the results, not just the system")
    }

    func testArmingOneProcessAndPressingAnotherKillsNothing() async throws {
        let first = try startSleep()
        let second = try startSleep()
        defer {
            for process in [first, second] where process.isRunning { process.terminate() }
        }
        let firstPid = Int(first.processIdentifier)
        let secondPid = Int(second.processIdentifier)
        let host = Host(self)
        let session = try await host.session("KillProcess")
        defer { Task { await session.stop() } }
        let opened = try await session.openView("search", query: CommandQuery(text: "sleep 31337"))
        let firstQuit = try XCTUnwrap(opened.root?.rows.first { $0.key == "\(firstPid)" }?.actions.first { $0.title == "Quit Process" })
        let secondQuit = try XCTUnwrap(opened.root?.rows.first { $0.key == "\(secondPid)" }?.actions.first { $0.title == "Quit Process" })

        try await session.event(firstQuit.id)
        try await session.event(secondQuit.id)
        XCTAssertTrue(first.isRunning && second.isRunning, "a first press on each only asks again")
        let armed = await rows(session, opened.session)
        XCTAssertEqual(armed.first { $0.key == "\(firstPid)" }?.subtitle, "Press again to quit sleep")
        XCTAssertEqual(armed.first { $0.key == "\(secondPid)" }?.subtitle, "Press again to quit sleep")

        // The second press on B ends B, and only B.
        try await session.event(secondQuit.id)
        let bEnded = await waitUntil(5) { !second.isRunning }
        XCTAssertTrue(bEnded, "B's second press ends B")
        XCTAssertTrue(first.isRunning, "A was only armed, so it keeps running")
    }

    func testProtectedProcessesHaveNoQuitAction() async throws {
        let host = Host(self)
        let session = try await host.session("KillProcess")
        defer { Task { await session.stop() } }
        var checked = 0
        for name in ["launchd", "Dock"] {
            let opened = try await session.openView("search", query: CommandQuery(text: name))
            for row in opened.root?.rows ?? [] where row.title == name {
                checked += 1
                XCTAssertFalse(row.actions.contains { $0.title.hasPrefix("Quit") }, "\(name) can't be quit")
            }
            await session.closeView(opened.session)
        }
        try XCTSkipIf(checked == 0, "launchd and Dock aren't listed on this Mac, so there is no row to check")
    }

    func testSearchFindsAProcessByItsCommandLine() async throws {
        let sleeper = try startSleep()
        defer { if sleeper.isRunning { sleeper.terminate() } }
        let pid = Int(sleeper.processIdentifier)
        let host = Host(self)
        let session = try await host.session("KillProcess")
        defer { Task { await session.stop() } }
        // "bin/sleep" appears in the command line, not in the name.
        let opened = try await session.openView("search", query: CommandQuery(text: "bin/sleep"))
        let found = try XCTUnwrap(opened.root?.rows.first { $0.key == "\(pid)" }, "search reads the command line too")
        XCTAssertEqual(found.title, "sleep")
        XCTAssertEqual(found.subtitle?.hasPrefix("sleep 31337"), true, "the subtitle drops the program's own path: \(found.subtitle ?? "")")
    }
    #endif
}
