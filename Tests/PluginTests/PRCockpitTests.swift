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
    /// Pull requests that are approved with green checks, drafts, and ones
    /// with auto-merge on. Their repository squashes.
    var ready: Set<Int> = []
    var drafts: Set<Int> = []
    var autoMerge: Set<Int> = []
}

private func gitHub(_ method: String, _ path: String, _ auth: String, _ answers: Answers, body: Data = Data()) -> (Int, String) {
    if method == "POST", path == "/api/graphql", String(decoding: body, as: UTF8.self).contains("mutation") {
        return (200, #"{"data":{}}"#)
    }
    if method == "POST", path == "/api/graphql" {
        return auth == "Bearer C" ? (401, #"{"message":"Bad credentials"}"#) : (200, graphQL(answers, auth: auth))
    }
    if method == "GET", path.hasPrefix("/api/v3/issues") { return (200, "[]") }
    if method == "GET", path.hasPrefix("/api/v3/notifications") { return (200, "[" + (answers.threads[auth] ?? []).joined(separator: ",") + "]") }
    if method == "POST", path.hasSuffix("/reviews") { return (200, "{}") }
    if method == "PUT", path.hasSuffix("/merge") { return (200, #"{"merged":true}"#) }
    if method == "DELETE", path.hasPrefix("/api/v3/notifications/threads/") { return (204, "") }
    if method == "GET", path.hasPrefix("/api/v3/repos/o/r/pulls/5/files") {
        return (200, #"[{"filename":"Sources/App/Checkout.swift","status":"modified","additions":3,"deletions":1,"patch":"@@ -1 +1,3 @@\n-old\n+new"},{"filename":"logo.png","status":"added","additions":0,"deletions":0}]"#)
    }
    if method == "PUT", path == "/api/v3/notifications" { return (205, "") }
    return (404, #"{"message":"Not Found"}"#)
}

private func graphQL(_ answers: Answers, auth: String) -> String {
    func search(_ numbers: [Int], state: String, total: Int?) -> String {
        let count = total.map { "\"issueCount\":\($0)," } ?? ""
        let nodes = numbers.map { pullRequest($0, state: state, answers) }.joined(separator: ",")
        return "{" + count + "\"nodes\":[" + nodes + "]}"
    }
    let review = answers.review[auth] ?? []
    return "{\"data\":{\"review\":" + search(review, state: "OPEN", total: answers.reviewTotal ?? review.count)
        + ",\"mine\":" + search(answers.mine[auth] ?? [], state: "OPEN", total: nil)
        + ",\"closed\":" + search(answers.merged[auth] ?? [], state: "MERGED", total: nil) + "}}"
}

private func pullRequest(_ number: Int, state: String, _ answers: Answers = Answers()) -> String {
    let ready = answers.ready.contains(number)
    let draft = answers.drafts.contains(number)
    let review = ready ? "APPROVED" : "REVIEW_REQUIRED"
    let checks = ready ? #"[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]"# : #"[{"commit":{"statusCheckRollup":{"state":"PENDING"}}}]"#
    let auto = answers.autoMerge.contains(number) ? #"{"enabledAt":"2026-11-01T00:00:00Z"}"# : "null"
    return #"{"nodeID":"PR_\#(number)","number":\#(number),"title":"PR \#(number)","url":"https://github.example/o/r/pull/\#(number)","isDraft":\#(draft),"updatedAt":"2026-11-01T00:00:00Z","state":"\#(state)","repository":{"nameWithOwner":"o/r","viewerDefaultMergeMethod":"SQUASH"},"author":{"login":"a"},"autoMergeRequest":\#(auto),"reviewDecision":"\#(review)","mergeable":"MERGEABLE","headRefName":"b","additions":1,"deletions":1,"comments":{"totalCount":0},"commits":{"nodes":\#(checks)}}"#
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
    /// gh has no sign-in for the stub's loopback host, so without a token
    /// neither way in works — on any machine the tests run on.
    private func connect(_ host: Host, _ stub: GitHubStub) async throws {
        try host.services.secrets.setSecret("http://127.0.0.1:\(stub.port)", for: "GITHUB_ENTERPRISE_URL")
        try await host.services.storage.set("enterprise", "true", for: id)
    }

    /// `connect`, with a `GITHUB_TOKEN` pasted.
    private func connect(_ host: Host, _ stub: GitHubStub, token: String) async throws {
        try host.services.secrets.setSecret(token, for: "GITHUB_TOKEN")
        try await connect(host, stub)
    }

    /// A host whose `gh` is a stub script: one that prints a token (signed
    /// in) or exits 1 (not signed in). Each run appends its arguments to a
    /// log, so a test can see how often gh ran and for which host; the
    /// script itself is handed back too, so a test can rewrite it (as when
    /// the user signs in). The plugin's choice of sign-in doesn't depend on
    /// the machine running the tests.
    private func ghHost(signedIn: Bool) throws -> (host: Host, log: URL, script: URL) {
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: bin) }
        let log = bin.appendingPathComponent("gh.log")
        let script = bin.appendingPathComponent("gh")
        try ("#!/bin/sh\necho \"$*\" >> '\(log.path)'\n" + (signedIn ? "printf GHSTUB\n" : "exit 1\n"))
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let gate = CommandRunGate(root: FileManager.default.temporaryDirectory.appendingPathComponent("stackbar-run-\(UUID().uuidString)", isDirectory: true),
                                  resolver: CommandResolver(directories: [bin.path]))
        return (Host(self, runs: gate), log, script)
    }

    /// What the stub gh was asked, one line per run.
    private func ghRuns(_ log: URL) -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
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

    /// Agent tools say how to connect instead of "nothing is waiting".
    func testAgentToolsSayWhenNoTokenIsSet() async throws {
        let stub = try GitHubStub { method, path, auth, _ in gitHub(method, path, auth, Answers()) }
        let host = Host(self)
        try await connect(host, stub)
        let supervisor = try await host.start("PRCockpit")
        let review = await supervisor.callTool("review_queue").text
        XCTAssertTrue(review.contains("gh auth login"), review)
        XCTAssertTrue(review.contains("GITHUB_TOKEN"), review)
        let issues = await supervisor.callTool("my_issues").text
        XCTAssertTrue(issues.contains("GITHUB_TOKEN"), issues)
        await supervisor.stop()
    }

    /// A pasted token wins even when gh is signed in: the user chose it,
    /// possibly a read-only fine-grained one, so gh is never asked while it
    /// serves and nothing says the secret is in use.
    func testThePastedTokenBeatsASignedInGh() async throws {
        let answers = Locked(Answers(review: ["Bearer A": [1]]))
        let stub = try GitHubStub { method, path, auth, _ in gitHub(method, path, auth, answers.current) }
        let gh = try ghHost(signedIn: true)
        try await connect(gh.host, stub, token: "A")
        let supervisor = try await gh.host.start("PRCockpit")
        _ = await waitUntil { await supervisor.views[.menuBar]?.plainText == "1" }
        XCTAssertTrue(stub.requests.all.contains { $0.contains(" Bearer A ") }, "\(stub.requests.all)")
        XCTAssertEqual(ghRuns(gh.log).count, 0, "gh is not asked while the pasted token serves")
        let panel = await panelText(supervisor)
        XCTAssertFalse(panel.contains("Using the GITHUB_TOKEN secret"), panel)
        await supervisor.stop()
    }

    /// With no pasted token, the signed-in gh command-line tool serves: its
    /// token reaches GitHub, asked once for the whole refresh and for the
    /// Enterprise server's host.
    func testGhServesWhenNoTokenIsPasted() async throws {
        let answers = Locked(Answers(review: ["Bearer GHSTUB": [1]]))
        let stub = try GitHubStub { method, path, auth, _ in gitHub(method, path, auth, answers.current) }
        let gh = try ghHost(signedIn: true)
        try await connect(gh.host, stub)
        let supervisor = try await gh.host.start("PRCockpit")
        _ = await waitUntil { await supervisor.views[.menuBar]?.plainText == "1" }
        XCTAssertTrue(stub.requests.all.contains { $0.contains(" Bearer GHSTUB ") }, "\(stub.requests.all)")
        let runs = ghRuns(gh.log)
        XCTAssertEqual(runs.count, 1, "one gh run serves the refresh and its follow-up requests: \(runs)")
        XCTAssertEqual(runs.first, "auth token --hostname 127.0.0.1", "the token is asked for the Enterprise server's host, not github.com")
        await supervisor.stop()
    }

    /// After gh auth login, pressing Try Again uses gh at once, without
    /// waiting out the five-minute memory of the earlier failure.
    func testTryAgainRetriesGhAfterSignIn() async throws {
        let answers = Locked(Answers(review: ["Bearer GHSTUB": [1]]))
        let stub = try GitHubStub { method, path, auth, _ in gitHub(method, path, auth, answers.current) }
        let gh = try ghHost(signedIn: false)
        try await connect(gh.host, stub)
        let supervisor = try await gh.host.start("PRCockpit")
        let connected = await waitUntil { await supervisor.views[.panel].map { TreeTextRenderer.render($0) }?.contains("Connect to GitHub") == true }
        XCTAssertTrue(connected, "the panel starts in the connect state")
        try "#!/bin/sh\nprintf GHSTUB\n".write(to: gh.script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.script.path)
        await supervisor.press(ActionID("button/Try Again"))
        let loaded = await waitUntil { await supervisor.views[.menuBar]?.plainText == "1" }
        let panel = await supervisor.views[.panel].map { TreeTextRenderer.render($0) } ?? "(none)"
        XCTAssertTrue(loaded, "signing in to gh and pressing Try Again loads the lists; panel: \(panel) | gh runs: \(ghRuns(gh.log))")
        XCTAssertTrue(stub.requests.all.contains { $0.contains(" Bearer GHSTUB ") }, "\(stub.requests.all)")
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

    /// Without either way in, the window explains both, not empty lists.
    func testWindowSaysHowToConnectWhenThereIsNoToken() async throws {
        let stub = try GitHubStub { method, path, auth, _ in gitHub(method, path, auth, Answers()) }
        let host = Host(self)
        try await connect(host, stub)
        let supervisor = try await host.start("PRCockpit")
        let window = await supervisor.views[.window].map { TreeTextRenderer.render($0) } ?? ""
        XCTAssertTrue(window.contains("Connect to GitHub"), window)
        XCTAssertTrue(window.contains("paste a GITHUB_TOKEN"), window)
        XCTAssertFalse(window.contains("Waiting on your review"), window)
        await supervisor.stop()
    }

    // MARK: Merging, drafts and files (after Raycast's GitHub extension)

    /// The stub and a session showing your pull requests in the panel.
    private func mineSession(_ answers: Locked<Answers>) async throws -> (GitHubStub, PluginSession) {
        let stub = try GitHubStub { method, path, auth, body in gitHub(method, path, auth, answers.current, body: body) }
        let host = Host(self)
        try await connect(host, stub, token: "A")
        try await host.services.storage.set("tab", #""Mine""#, for: id)
        let session = try await host.session("PRCockpit")
        return (stub, session)
    }

    private func action(_ session: PluginSession, _ title: String) async -> ActionRef? {
        _ = await waitUntil { await session.view(.panel)?.rows.contains { $0.actions.contains { $0.title == title } } == true }
        return await session.view(.panel)?.rows.lazy.compactMap { $0.actions.first { $0.title == title } }.first
    }

    /// A ready pull request of yours merges the way its repository does,
    /// on the second press.
    func testMergeAsksThenUsesTheRepositorysMethod() async throws {
        let (stub, session) = try await mineSession(Locked(Answers(mine: ["Bearer A": [5]], ready: [5])))
        let mergeFound = await action(session, "Squash and merge")
        let merge = try XCTUnwrap(mergeFound, "a ready pull request offers its repository's merge")
        XCTAssertEqual(merge.confirm, "squash and merge o/r#5")
        let held = try await session.event(merge.id)
        XCTAssertNotNil(held, "Stackbar holds the first press")
        XCTAssertFalse(stub.requests.all.contains { $0.hasPrefix("PUT ") })
        try await session.event(merge.id)
        XCTAssertTrue(stub.requests.all.contains("PUT /api/v3/repos/o/r/pulls/5/merge Bearer A {\"merge_method\":\"squash\"}"), "\(stub.requests.all)")
        await session.stop()
    }

    /// One still waiting on checks offers auto-merge; one with it on offers to turn it off.
    func testAutoMergeTurnsOnAndOff() async throws {
        let (stub, session) = try await mineSession(Locked(Answers(mine: ["Bearer A": [5, 6]], autoMerge: [6])))
        let enableFound = await action(session, "Enable Auto-Merge")
        let enable = try XCTUnwrap(enableFound)
        let held = try await session.event(enable.id)
        XCTAssertNotNil(held, "turning it on asks first")
        try await session.event(enable.id)
        XCTAssertTrue(stub.requests.all.contains { $0.contains("enablePullRequestAutoMerge") && $0.contains(#"\"PR_5\""#) && $0.contains("SQUASH") }, "\(stub.requests.all)")
        let disableFound = await action(session, "Disable Auto-Merge")
        let disable = try XCTUnwrap(disableFound)
        XCTAssertNil(disable.confirm, "turning it off needs no question")
        try await session.event(disable.id)
        XCTAssertTrue(stub.requests.all.contains { $0.contains("disablePullRequestAutoMerge") && $0.contains(#"\"PR_6\""#) }, "\(stub.requests.all)")
        await session.stop()
    }

    func testADraftOfYoursCanBeMarkedReady() async throws {
        let (stub, session) = try await mineSession(Locked(Answers(mine: ["Bearer A": [7]], drafts: [7])))
        let readyFound = await action(session, "Mark Ready for Review")
        let ready = try XCTUnwrap(readyFound)
        XCTAssertEqual(ready.confirm, "mark o/r#7 ready for review")
        try await session.event(ready.id, confirmed: true)
        XCTAssertTrue(stub.requests.all.contains { $0.contains("markPullRequestReadyForReview") && $0.contains(#"\"PR_7\""#) }, "\(stub.requests.all)")
        await session.stop()
    }

    /// View Diff lists the files with each one's patch beside the list.
    func testViewDiffListsTheFilesWithTheirPatches() async throws {
        let (stub, session) = try await mineSession(Locked(Answers(mine: ["Bearer A": [5]])))
        _ = await action(session, "Open in browser")
        let opened = try await session.openView("files", query: CommandQuery(arguments: ["url": "https://github.example/o/r/pull/5"]))
        _ = await waitUntil { (await session.commandView(opened.session)?.rows.count ?? 0) == 2 }
        let rows = await session.commandView(opened.session)?.rows ?? []
        let shown = await session.commandView(opened.session).map { TreeTextRenderer.render($0) } ?? "(no view)"
        XCTAssertEqual(rows.map(\.title), ["Checkout.swift", "logo.png"], "\(shown)\n\(stub.requests.all.filter { $0.contains("/files") })")
        XCTAssertEqual(rows.first?.subtitle, "Sources/App · +3 −1")
        XCTAssertEqual(rows.first?.preview?.text, "@@ -1 +1,3 @@\n-old\n+new")
        await session.stop()
    }
}
#endif
