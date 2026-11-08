import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

#if canImport(Network)
import Network

/// A GitHub Enterprise server on loopback. The plugin's requests reach it
/// through the host like any other, and `requests` records each one as
/// "METHOD path auth body".
private final class GitHubStub: @unchecked Sendable {
    let listener: NWListener
    let requests = Recorder<String>()
    var port: Int { Int(listener.port!.rawValue) }
    init(_ handle: @escaping @Sendable (_ method: String, _ path: String, _ auth: String, _ body: Data) -> (Int, String)) throws {
        listener = try NWListener(using: .tcp, on: .any)
        let requests = requests
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            @Sendable func read(_ sofar: Data) {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, error in
                    let buffer = sofar + (data ?? Data())
                    guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { if !done && error == nil { read(buffer) }; return }
                    let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                    var headers: [String: String] = [:]
                    for line in head.dropFirst() { if let c = line.firstIndex(of: ":") { headers[line[..<c].lowercased()] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces) } }
                    let body = Data(buffer[end.upperBound...])
                    if body.count < (Int(headers["content-length"] ?? "0") ?? 0) && !done { read(buffer); return }
                    let parts = head[0].split(separator: " ").map(String.init)
                    let auth = headers["authorization"] ?? ""
                    requests.record("\(parts[0]) \(parts[1]) \(auth) \(String(decoding: body, as: UTF8.self))")
                    let (status, text) = handle(parts[0], parts[1], auth, body)
                    let payload = Data(text.utf8)
                    let reply = "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(reply.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            read(Data())
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: .global()); ready.wait()
    }
    deinit { listener.cancel() }
}

/// What the stub answers from, changed by a test between refreshes.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    var current: Value { lock.withLock { value } }
    func change(_ edit: (inout Value) -> Void) { lock.withLock { edit(&value) } }
}

/// What the stub answers, keyed by the Authorization header a request sent.
private struct Answers: Sendable {
    /// Pull requests waiting on review, and yours open.
    var review: [String: [Int]] = [:]
    var mine: [String: [Int]] = [:]
    /// Pull requests you opened that have merged.
    var merged: [String: [Int]] = [:]
    /// Notification threads, as JSON.
    var threads: [String: [String]] = [:]
    /// The total GitHub reports for review requests, when more than it sends.
    var reviewTotal: Int?
}

private func gitHub(_ method: String, _ path: String, _ auth: String, _ answers: Answers) -> (Int, String) {
    if method == "POST", path == "/api/graphql" {
        return auth == "Bearer C" ? (401, #"{"message":"Bad credentials"}"#) : (200, graphQL(answers, auth: auth))
    }
    if method == "GET", path.hasPrefix("/api/v3/issues") { return (200, "[]") }
    if method == "GET", path.hasPrefix("/api/v3/notifications") { return (200, "[" + (answers.threads[auth] ?? []).joined(separator: ",") + "]") }
    if method == "POST", path.hasSuffix("/reviews") { return (200, "{}") }
    if method == "PUT", path == "/api/v3/notifications" { return (205, "") }
    return (404, #"{"message":"Not Found"}"#)
}

private func graphQL(_ answers: Answers, auth: String) -> String {
    func search(_ numbers: [Int], state: String, total: Int?) -> String {
        let count = total.map { "\"issueCount\":\($0)," } ?? ""
        let nodes = numbers.map { pullRequest($0, state: state) }.joined(separator: ",")
        return "{" + count + "\"nodes\":[" + nodes + "]}"
    }
    let review = answers.review[auth] ?? []
    return "{\"data\":{\"review\":" + search(review, state: "OPEN", total: answers.reviewTotal ?? review.count)
        + ",\"mine\":" + search(answers.mine[auth] ?? [], state: "OPEN", total: nil)
        + ",\"closed\":" + search(answers.merged[auth] ?? [], state: "MERGED", total: nil) + "}}"
}

private func pullRequest(_ number: Int, state: String) -> String {
    #"{"number":\#(number),"title":"PR \#(number)","url":"https://github.example/o/r/pull/\#(number)","isDraft":false,"updatedAt":"2026-11-01T00:00:00Z","state":"\#(state)","repository":{"nameWithOwner":"o/r"},"author":{"login":"a"},"reviewDecision":"REVIEW_REQUIRED","mergeable":"MERGEABLE","headRefName":"b","additions":1,"deletions":1,"comments":{"totalCount":0},"commits":{"nodes":[]}}"#
}

private func mentionThread(_ id: Int) -> String {
    #"{"id":"\#(id)","reason":"mention","unread":true,"updated_at":"2026-11-01T00:00:00Z","subject":{"title":"Thread \#(id)","url":"https://api.github.example/repos/o/r/issues/\#(id)","type":"Issue"},"repository":{"full_name":"o/r","html_url":"https://github.example/o/r"}}"#
}

final class PRCockpitTests: XCTestCase {
    private let id = "io.navbytes.stackbar.pr-cockpit"

    /// Waits out a refresh the test asked for.
    private func refreshed(_ supervisor: PluginSupervisor) async {
        let before = await supervisor.settledCount
        await supervisor.refresh()
        _ = await waitUntil { await supervisor.settledCount > before }
    }

    /// Points the plugin at the stub as a GitHub Enterprise server. Enterprise
    /// is switched on in storage, so the first refresh never reaches github.com.
    private func connect(_ host: Host, _ stub: GitHubStub, token: String) async throws {
        try host.services.secrets.setSecret(token, for: "GITHUB_TOKEN")
        try host.services.secrets.setSecret("http://127.0.0.1:\(stub.port)", for: "GITHUB_ENTERPRISE_URL")
        try await host.services.storage.set("enterprise", "true", for: id)
    }

    private func panelText(_ supervisor: PluginSupervisor) async -> String {
        await supervisor.views[.panel].map { TreeTextRenderer.render($0) } ?? ""
    }

    /// A new token is another account: its review requests are not news, and
    /// the old account's lists don't stay on screen.
    func testSwitchingTokenDoesNotAnnounceTheNewAccount() async throws {
        let answers = Locked(Answers(review: ["Bearer A": [1], "Bearer B": [10, 11, 12]]))
        let stub = try GitHubStub { method, path, auth, _ in gitHub(method, path, auth, answers.current) }
        let host = Host(self)
        try await connect(host, stub, token: "A")
        let supervisor = try await host.start("PRCockpit")
        _ = await waitUntil { await supervisor.views[.menuBar]?.plainText == "1" }
        await supervisor.press("toggle/Use GitHub Enterprise Server", value: .bool(true))
        _ = await waitUntil { await supervisor.views[.menuBar]?.plainText == "1" }

        try host.services.secrets.setSecret("B", for: "GITHUB_TOKEN")
        await refreshed(supervisor)
        let menu = await supervisor.views[.menuBar]?.plainText
        XCTAssertEqual(menu, "3")
        XCTAssertTrue(stub.requests.all.contains { $0.contains(" Bearer B ") })
        XCTAssertTrue(host.notifications.all.isEmpty, "\(host.notifications.all.map(\.title))")

        // A review request that arrives on the new account is still news.
        answers.change { $0.review["Bearer B", default: []].append(13) }
        await refreshed(supervisor)
        XCTAssertEqual(host.notifications.all.map(\.title), ["Review requested: PR 13"])
        await supervisor.stop()
    }

    /// Several merges in one refresh are one notification, not a burst.
    func testManyMergesAreOneNotification() async throws {
        let answers = Locked(Answers(mine: ["Bearer A": [1, 2, 3, 4]]))
        let stub = try GitHubStub { method, path, auth, _ in gitHub(method, path, auth, answers.current) }
        let host = Host(self)
        try await connect(host, stub, token: "A")
        let supervisor = try await host.start("PRCockpit")
        _ = await waitUntil { await self.panelText(supervisor).contains("4 of yours open") }

        answers.change {
            $0.mine = [:]
            $0.merged = ["Bearer A": [1, 2, 3, 4]]
        }
        await refreshed(supervisor)
        XCTAssertEqual(host.notifications.all.map(\.title), ["4 of your pull requests merged or closed"])
        XCTAssertEqual(host.notifications.all.first?.body, "PR 1\nPR 2\nPR 3")
        await supervisor.stop()
    }

    /// Several mentions in one refresh are one notification, not a burst.
    func testManyMentionsAreOneNotification() async throws {
        let answers = Locked(Answers(threads: ["Bearer A": []]))
        let stub = try GitHubStub { method, path, auth, _ in gitHub(method, path, auth, answers.current) }
        let host = Host(self)
        try await connect(host, stub, token: "A")
        try await host.services.storage.set("showInbox", "true", for: id)
        let supervisor = try await host.start("PRCockpit")

        answers.change { $0.threads["Bearer A"] = [1, 2, 3, 4].map(mentionThread) }
        await refreshed(supervisor)
        XCTAssertEqual(host.notifications.all.map(\.title), ["4 new mentions on GitHub"])
        await supervisor.stop()
    }

    /// Mark All as Read asks Stackbar for a second press, and only the second
    /// one reaches GitHub.
    func testMarkAllAsReadWaitsForASecondPress() async throws {
        let answers = Locked(Answers(threads: ["Bearer A": [1, 2].map(mentionThread)]))
        let stub = try GitHubStub { method, path, auth, _ in gitHub(method, path, auth, answers.current) }
        let host = Host(self)
        try await connect(host, stub, token: "A")
        let session = try await host.session("PRCockpit")
        let opened = try await session.openView("inbox")
        let loaded = await waitUntil { await session.commandView(opened.session)?.rows.count == 3 }
        XCTAssertTrue(loaded, "two threads and Mark All as Read")

        let markAll = ActionID("view/\(opened.session)/row/inbox-mark-all/Mark All as Read")
        let held = try await session.event(markAll)
        XCTAssertEqual(held?.text, "mark 2 as read")
        XCTAssertFalse(stub.requests.all.contains { $0.hasPrefix("PUT ") }, "the first press only asks")
        try await session.event(markAll)
        XCTAssertEqual(stub.requests.all.filter { $0.hasPrefix("PUT /api/v3/notifications ") }.count, 1)
        let put = stub.requests.all.first { $0.hasPrefix("PUT ") } ?? ""
        XCTAssertTrue(put.contains("\"last_read_at\""), "only what was fetched is marked: \(put)")
        await session.stop()
    }

    /// Approve asks Stackbar for a second press, then posts an approving review.
    func testApproveSendsAReviewOnlyOnTheSecondPress() async throws {
        let answers = Locked(Answers(review: ["Bearer A": [1]]))
        let stub = try GitHubStub { method, path, auth, _ in gitHub(method, path, auth, answers.current) }
        let host = Host(self)
        try await connect(host, stub, token: "A")
        let session = try await host.session("PRCockpit")
        _ = await waitUntil { await session.view(.panel)?.rows.first?.actions.contains { $0.title == "Approve" } == true }
        let panel = await session.view(.panel)
        let approve = try XCTUnwrap(panel?.rows.first?.actions.first { $0.title == "Approve" })
        XCTAssertEqual(approve.confirm, "approve o/r#1")
        let held = try await session.event(approve.id)
        XCTAssertNotNil(held, "Stackbar holds the first press")
        XCTAssertFalse(stub.requests.all.contains { $0.hasPrefix("POST /api/v3/repos/") }, "the first press only asks: \(stub.requests.all)")
        try await session.event(approve.id)
        XCTAssertTrue(stub.requests.all.contains("POST /api/v3/repos/o/r/pulls/1/reviews Bearer A {\"event\":\"APPROVE\"}"), "\(stub.requests.all)")
        await session.stop()
    }

    /// GitHub can list more pull requests than the 40 fetched; the panel says so.
    func testListsSayWhenGitHubHasMoreThanTheyShow() async throws {
        let answers = Locked(Answers(review: ["Bearer A": [1]], reviewTotal: 45))
        let stub = try GitHubStub { method, path, auth, _ in gitHub(method, path, auth, answers.current) }
        let host = Host(self)
        try await connect(host, stub, token: "A")
        let supervisor = try await host.start("PRCockpit")
        _ = await waitUntil { await supervisor.views[.menuBar]?.plainText == "1" }
        let panel = await panelText(supervisor)
        XCTAssertTrue(panel.contains("Showing the 40 most recently updated of 45."), panel)
        await supervisor.stop()
    }

    /// A rejected token says so in the palette, not as a bare error code.
    func testSearchSaysWhenGitHubRejectsTheToken() async throws {
        let answers = Locked(Answers())
        let stub = try GitHubStub { method, path, auth, _ in gitHub(method, path, auth, answers.current) }
        let host = Host(self)
        try await connect(host, stub, token: "C")
        let session = try await host.session("PRCockpit")
        let opened = try await session.openView("search", query: CommandQuery(text: "login bug"))
        let shown = await waitUntil {
            guard let view = await session.commandView(opened.session) else { return false }
            return TreeTextRenderer.render(view).contains("rejected the token (401)")
        }
        XCTAssertTrue(shown, "the search names the rejected token")
        await session.stop()
    }

    /// Agent tools say a token is missing instead of "nothing is waiting".
    func testAgentToolsSayWhenNoTokenIsSet() async throws {
        let host = Host(self)
        let supervisor = try await host.start("PRCockpit")
        let review = await supervisor.callTool("review_queue").text
        XCTAssertTrue(review.contains("GitHub token"), review)
        let issues = await supervisor.callTool("my_issues").text
        XCTAssertTrue(issues.contains("GitHub token"), issues)
        await supervisor.stop()
    }

    /// After a refresh the listed pull requests' checks are fetched together,
    /// so the palette previews them; a second refresh with nothing changed
    /// asks for no checks.
    func testThePalettePreviewsChecksFetchedInTheBackground() async throws {
        let answers = Locked(Answers(review: ["Bearer A": [1]], mine: ["Bearer A": [2]]))
        let stub = try GitHubStub { method, path, auth, body in
            let text = String(decoding: body, as: UTF8.self)
            if path == "/api/graphql", text.contains("p0: repository") {
                let failed = #"{"__typename":"CheckRun","databaseId":7,"name":"test","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://ci/7","isRequired":true,"steps":{"nodes":[{"name":"Run tests","conclusion":"FAILURE"}]},"annotations":{"nodes":[]}}"#
                let passed = #"{"__typename":"CheckRun","databaseId":8,"name":"lint","status":"COMPLETED","conclusion":"SUCCESS","isRequired":false,"steps":{"nodes":[]},"annotations":{"nodes":[]}}"#
                func pull(_ check: String) -> String { #"{"pullRequest":{"commits":{"nodes":[{"commit":{"oid":"abc","statusCheckRollup":{"contexts":{"nodes":[\#(check)]}},"deployments":{"nodes":[]}}}]}}}"# }
                return (200, #"{"data":{"p0":\#(pull(failed)),"p1":\#(pull(passed))}}"#)
            }
            return gitHub(method, path, auth, answers.current)
        }
        let host = Host(self)
        try await connect(host, stub, token: "A")
        let session = try await host.session("PRCockpit")
        try await session.refresh()
        let batches = { stub.requests.all.filter { $0.contains("p0: repository") } }
        XCTAssertEqual(batches().count, 1, "one request for both pull requests")
        XCTAssertTrue(batches().first?.contains("p1: repository") == true)

        let opened = try await session.openView("search", query: CommandQuery(text: ""))
        let rows = opened.root?.rows ?? []
        let review = try XCTUnwrap(rows.first { $0.title == "PR 1" })
        XCTAssertEqual(review.preview?.caption, "1 failed")
        XCTAssertTrue(review.preview?.text?.contains("✕ test: Run tests") == true, review.preview?.text ?? "")
        XCTAssertEqual(rows.first { $0.title == "PR 2" }?.preview?.caption, "1 passed")

        try await session.refresh()
        XCTAssertEqual(batches().count, 1, "nothing changed, so no checks are asked for again")
        await session.stop()
    }

    /// Without a token the window explains how to connect, not empty lists.
    func testWindowSaysHowToConnectWhenThereIsNoToken() async throws {
        let host = Host(self)
        let supervisor = try await host.start("PRCockpit")
        let window = await supervisor.views[.window].map { TreeTextRenderer.render($0) } ?? ""
        XCTAssertTrue(window.contains("Paste a GitHub token above"), window)
        XCTAssertFalse(window.contains("Waiting on your review"), window)
        await supervisor.stop()
    }
}
#endif
