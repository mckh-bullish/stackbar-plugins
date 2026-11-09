import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

#if canImport(Network)
import Network

/// A LiteLLM proxy on loopback. The plugin's requests reach it through the
/// host like any other, and `requests` records each one as "METHOD path auth body".
private final class LiteLLMStub: @unchecked Sendable {
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

private struct Proxy: Sendable {
    var user = "uA"
    /// Tokens each day; the model mix splits them 60/40.
    var tokensPerDay = 1_000_000
    /// The `/key/info` reply for a key with its own budget; nil answers 404.
    var keyInfo: String?
    /// Answers every request with 500, like a proxy that is down.
    var failing = false
}

private func answer(_ method: String, _ target: String, _ proxy: Proxy) -> (Int, String) {
    if proxy.failing { return (500, #"{"error":"down"}"#) }
    let url = URLComponents(string: "http://proxy" + target)
    switch url?.path ?? "" {
    case "/user/info":
        return (200, "{\"user_id\":\"\(proxy.user)\",\"user_info\":{\"spend\":5}}")
    case "/key/info":
        return proxy.keyInfo.map { (200, $0) } ?? (404, #"{"error":"not found"}"#)
    case "/user/daily/activity":
        let query = url?.queryItems ?? []
        let start = query.first { $0.name == "start_date" }?.value ?? ""
        let end = query.first { $0.name == "end_date" }?.value ?? ""
        let results = dates(from: start, to: end).map { day in
            "{\"date\":\"\(day)\",\"metrics\":{\"total_tokens\":\(proxy.tokensPerDay),\"spend\":0.1,\"api_requests\":10},"
                + "\"breakdown\":{\"models\":{\"anthropic/claude-sonnet\":{\"metrics\":{\"total_tokens\":\(proxy.tokensPerDay * 6 / 10),\"spend\":0.06}},"
                + "\"gpt-mini\":{\"metrics\":{\"total_tokens\":\(proxy.tokensPerDay * 4 / 10),\"spend\":0.04}}}}}"
        }
        return (200, "{\"results\":[" + results.joined(separator: ",") + "],\"metadata\":{\"total_pages\":1}}")
    default:
        return (404, #"{"error":"not found"}"#)
    }
}

/// Each day from `start` to `end`, inclusive, as yyyy-MM-dd.
private func dates(from start: String, to end: String) -> [String] {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd"
    guard var day = formatter.date(from: start), let last = formatter.date(from: end) else { return [] }
    var days: [String] = []
    while day <= last {
        days.append(formatter.string(from: day))
        day = day.addingTimeInterval(86400)
    }
    return days
}

final class LiteLLMTests: XCTestCase {
    private let id = "io.navbytes.stackbar.plugins.litellm"

    /// Waits out a refresh the test asked for.
    private func refreshed(_ supervisor: PluginSupervisor) async {
        let before = await supervisor.settledCount
        await supervisor.refresh()
        _ = await waitUntil { await supervisor.settledCount > before }
    }

    private func panelText(_ supervisor: PluginSupervisor) async -> String {
        await supervisor.views[.panel].map { TreeTextRenderer.render($0) } ?? ""
    }

    /// The values of the panel's trend chart, the first area chart.
    private func trendValues(_ supervisor: PluginSupervisor) async -> [Double] {
        let panel = await supervisor.views[.panel]
        return panel?.charts.first { $0.kind == .area }?.values ?? []
    }

    /// A switch to another proxy starts its history over. Its numbers are
    /// much smaller than the old proxy's, so any of the old ones left would show.
    func testSwitchingProxyStartsItsHistoryFresh() async throws {
        let first = Locked(Proxy(user: "uA", tokensPerDay: 1_000_000))
        let second = Locked(Proxy(user: "uB", tokensPerDay: 7_000))
        let proxyA = try LiteLLMStub { method, path, _, _ in answer(method, path, first.current) }
        let proxyB = try LiteLLMStub { method, path, _, _ in answer(method, path, second.current) }
        let host = Host(self)
        try host.services.secrets.setSecret("http://127.0.0.1:\(proxyA.port)", for: "LITELLM_PROXY_URL")
        try host.services.secrets.setSecret("k", for: "LITELLM_API_KEY")
        let supervisor = try await host.start("LiteLLM")
        _ = await waitUntil { await self.trendValues(supervisor).contains { $0 > 0 } }

        try host.services.secrets.setSecret("http://127.0.0.1:\(proxyB.port)", for: "LITELLM_PROXY_URL")
        await refreshed(supervisor)
        await supervisor.press("picker/Range", value: .text("6M"))
        let values = await trendValues(supervisor)
        XCTAssertEqual(values.count, 26, "six months as weeks: \(values)")
        XCTAssertLessThanOrEqual(values.max() ?? 0, 7 * 7_000, "no week of the old proxy's numbers: \(values)")
        await supervisor.stop()
    }

    /// A key with its own budget shows it when its user has no budget.
    func testAKeysOwnBudgetShowsWhenItsUserHasNone() async throws {
        let proxy = Locked(Proxy(keyInfo: #"{"key":"k","info":{"spend":12,"max_budget":50}}"#))
        let stub = try LiteLLMStub { method, path, _, _ in answer(method, path, proxy.current) }
        let host = Host(self)
        try host.services.secrets.setSecret("http://127.0.0.1:\(stub.port)", for: "LITELLM_PROXY_URL")
        try host.services.secrets.setSecret("k", for: "LITELLM_API_KEY")
        let supervisor = try await host.start("LiteLLM")
        _ = await waitUntil { await self.panelText(supervisor).contains("of $50.00") }
        let panel = await panelText(supervisor)
        XCTAssertTrue(panel.contains("$12.00 of $50.00"), panel)
        XCTAssertTrue(stub.requests.all.contains { $0.hasPrefix("GET /key/info") }, "the key's budget was asked for")
        await supervisor.stop()
    }

    /// A key with no budget of its own is asked about once an hour, not on every refresh.
    func testAKeyWithoutABudgetIsNotAskedAboutOnEveryRefresh() async throws {
        let stub = try LiteLLMStub { method, path, _, _ in answer(method, path, Proxy()) }
        let host = Host(self)
        try host.services.secrets.setSecret("http://127.0.0.1:\(stub.port)", for: "LITELLM_PROXY_URL")
        try host.services.secrets.setSecret("k", for: "LITELLM_API_KEY")
        let supervisor = try await host.start("LiteLLM")
        await refreshed(supervisor)
        await refreshed(supervisor)
        let asked = stub.requests.all.filter { $0.hasPrefix("GET /key/info") }.count
        XCTAssertEqual(asked, 1, "\(stub.requests.all)")
        await supervisor.stop()
    }

    /// The panel shows what each model cost today, the most expensive first.
    func testThePanelShowsTodaysCostPerModel() async throws {
        let stub = try LiteLLMStub { method, path, _, _ in answer(method, path, Proxy()) }
        let host = Host(self)
        try host.services.secrets.setSecret("http://127.0.0.1:\(stub.port)", for: "LITELLM_PROXY_URL")
        try host.services.secrets.setSecret("k", for: "LITELLM_API_KEY")
        let supervisor = try await host.start("LiteLLM")
        _ = await waitUntil { await self.panelText(supervisor).contains("TODAY BY MODEL") }
        let panel = await panelText(supervisor)
        XCTAssertTrue(panel.contains("TODAY BY MODEL"), panel)
        XCTAssertTrue(panel.contains("$0.06 · 600K tokens"), panel)
        XCTAssertTrue(panel.contains("$0.04 · 400K tokens"), panel)
        let sonnet = panel.range(of: "claude-sonnet")?.lowerBound, mini = panel.range(of: "gpt-mini")?.lowerBound
        XCTAssertTrue(sonnet != nil && mini != nil && sonnet! < mini!, panel)
        await supervisor.stop()
    }

    /// Without a key the panel asks for one rather than saying the proxy can't be reached.
    func testWithoutAKeyThePanelAsksForOne() async throws {
        let stub = try LiteLLMStub { method, path, _, _ in answer(method, path, Proxy()) }
        let host = Host(self)
        try host.services.secrets.setSecret("http://127.0.0.1:\(stub.port)", for: "LITELLM_PROXY_URL")
        let supervisor = try await host.start("LiteLLM")
        let panel = await panelText(supervisor)
        XCTAssertTrue(panel.contains("Add your LiteLLM key"), panel)
        XCTAssertFalse(panel.contains("Can't reach the proxy"), panel)
        await supervisor.stop()
    }

    /// The Spend command lists the top models, asks the proxy once rather than
    /// on every open, and keeps the last numbers with a row saying why they are old.
    func testSpendListsModelsAndKeepsTheLastNumbersWhenTheProxyFails() async throws {
        let proxy = Locked(Proxy())
        let stub = try LiteLLMStub { method, path, _, _ in answer(method, path, proxy.current) }
        let host = Host(self)
        try host.services.secrets.setSecret("http://127.0.0.1:\(stub.port)", for: "LITELLM_PROXY_URL")
        try host.services.secrets.setSecret("k", for: "LITELLM_API_KEY")
        let session = try await host.session("LiteLLM")
        let userInfoRequests = { stub.requests.all.filter { $0.hasPrefix("GET /user/info") }.count }

        let before = userInfoRequests()
        let opened = try await session.openView("spend")
        _ = try await session.openView("spend")
        XCTAssertEqual(userInfoRequests(), before, "keystrokes in the palette don't refetch")
        let keys = opened.root?.rows.map(\.key) ?? []
        XCTAssertTrue(keys.contains("spend-model-claude-sonnet") && keys.contains("spend-model-gpt-mini"), "\(keys)")
        XCTAssertEqual(keys.filter { $0.hasPrefix("spend-today-") }, ["spend-today-claude-sonnet", "spend-today-gpt-mini"], "today's models, most expensive first")

        proxy.change { $0.failing = true }
        try await session.refresh()
        let stale = try await session.openView("spend")
        XCTAssertTrue(stale.root?.rows.contains { $0.key == "spend-stale" } ?? false, "the last numbers say the proxy failed")
        await session.stop()
    }
}
#endif
