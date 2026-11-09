import StackbarKit
import Foundation

/// Your Linear issues in the menu bar and the palette: what's assigned to
/// you, grouped by state, with the branch name a keystroke away, your inbox
/// with a notification when something needs you, status, priority and
/// comments from a row, and new issues filed without leaving what you're
/// doing.
///
/// It talks to Linear's GraphQL API with a personal API key (Settings >
/// Security & access > Personal API keys in Linear), kept in your Keychain
/// as `LINEAR_API_KEY`.
@main
final class Linear: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.linear",
        name: "Linear",
        version: "1.8.0",
        summary: "Your assigned Linear issues and inbox: change status and priority, start work, comment, and new issues from the palette.",
        surfaces: [.menuBar, .panel, .widget, .settings],
        triggers: [.launch, .minutes(5), .wake],
        capabilities: [.network("api.linear.app"), .secret(name: "LINEAR_API_KEY")],
        minimumStackbar: "0.35.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Developer/Linear",
        accent: .indigo,
        symbol: "circle.lefthalf.filled"
    )

    // MARK: Previews

    static let previews: [PreviewScene<Linear>] = [
        PreviewScene("hero", "Your Linear issues, by state and priority") { plugin in
            plugin.teams = [Team(id: "t1", key: "ENG", name: "Engineering"), Team(id: "t2", key: "DES", name: "Design")]
            plugin.defaultTeam = "t1"
            plugin.assigned = samples
            plugin.inbox = inboxSamples
            plugin.loaded = true
        },
        PreviewScene("widget", "What you're on, on your desktop", surface: .widget) { plugin in
            plugin.assigned = samples
            plugin.loaded = true
        },
    ]

    static let samples: [Issue] = {
        func issue(_ id: String, _ title: String, _ state: String, _ type: String, _ priority: Double) -> Issue {
            let team = String(id.prefix(3))
            return Issue(id: id, identifier: id, title: title, url: "https://linear.app/acme/issue/\(id)", branchName: "sam/\(id.lowercased())",
                         priority: priority, state: .init(name: state, type: type), team: .init(key: team))
        }
        return [
            issue("ENG-231", "Sign-in loops on Safari when cookies are blocked", "In Progress", "started", 1),
            issue("ENG-228", "Rate-limit the export endpoint", "In Progress", "started", 2),
            issue("DES-54", "Empty states for the new dashboard", "In Review", "started", 3),
            issue("ENG-240", "Move cron jobs to the queue", "Todo", "unstarted", 2),
            issue("ENG-243", "Flaky test: billing webhook retries", "Todo", "unstarted", 3),
            issue("ENG-219", "Audit log for admin actions", "Backlog", "backlog", 4),
        ]
    }()

    static let inboxSamples: [InboxItem] = [
        InboxItem(id: "n1", type: "issueAssignedToYou", readAt: nil, createdAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-600)),
                  actor: .init(name: "Ravi"), issue: .init(identifier: "ENG-247", title: "Webhooks drop events over 1 MB", url: "https://linear.app/acme/issue/ENG-247")),
        InboxItem(id: "n2", type: "issueMention", readAt: nil, createdAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600)),
                  actor: .init(name: "Mei"), issue: .init(identifier: "DES-54", title: "Empty states for the new dashboard", url: "https://linear.app/acme/issue/DES-54")),
    ]

    /// One entry in Linear's inbox.
    struct InboxItem: Codable, Equatable, Identifiable {
        struct Actor: Codable, Equatable { let name: String }
        struct Subject: Codable, Equatable { let identifier: String; let title: String; let url: String }
        let id: String
        let type: String
        let readAt: String?
        let createdAt: String
        let actor: Actor?
        let issue: Subject?

        /// "Ravi assigned you", "Mei mentioned you", from Linear's type names.
        var headline: String {
            let who = actor?.name ?? "Linear"
            switch type {
            case "issueAssignedToYou": return "\(who) assigned you"
            case "issueMention", "issueCommentMention", "issueDescriptionMention": return "\(who) mentioned you"
            case "issueNewComment", "issueCommentReaction": return "\(who) commented"
            case "issueStatusChanged": return "\(who) changed the status"
            case "issuePriorityUrgent": return "Marked urgent"
            case "issueBlocking", "issueUnblocked": return "Blocking changed"
            case "issueDue", "issueDueSoon": return "Due soon"
            default: return "\(who) updated it"
            }
        }

        var symbol: String {
            switch type {
            case "issueAssignedToYou": return "person.crop.circle.badge.plus"
            case "issueMention", "issueCommentMention", "issueDescriptionMention": return "at"
            case "issueNewComment", "issueCommentReaction": return "text.bubble"
            default: return "bell"
            }
        }
    }

    struct WorkflowState: Codable, Equatable, Identifiable {
        let id: String
        let name: String
        let type: String
        let position: Double
    }

    struct Issue: Codable, Equatable, Identifiable {
        struct State: Codable, Equatable { let name: String; let type: String }
        struct Team: Codable, Equatable {
            var id: String?
            let key: String
        }
        let id: String
        let identifier: String
        let title: String
        let url: String
        let branchName: String
        let priority: Double
        let state: State
        let team: Team
    }

    struct GraphQLReply<T: Decodable>: Decodable {
        struct Failure: Decodable { let message: String }
        let data: T?
        let errors: [Failure]?
    }

    struct Team: Codable, Equatable, Identifiable {
        let id: String
        let key: String
        let name: String
    }

    var assigned: [Issue] = []
    var found: [Issue] = []
    /// The title search `found` answers, so typing it again asks Linear nothing.
    var foundText: String?
    /// The issue an identifier typed at the palette's root names.
    var keyed: [String: Issue] = [:]
    /// When each identifier that wasn't found (or failed to load) was asked
    /// for, and why a failed one failed.
    var lookupMisses: [String: Date] = [:]
    var lookupProblems: [String: String] = [:]
    @Stored("teams") var teams: [Team] = []
    @Stored("defaultTeam") var defaultTeam = ""
    @Stored("menuBarCount") var menuBarCount = "In progress"
    @Stored("notify") var notifyInbox = true
    /// Inbox entries already seen, so only new ones notify. The first good
    /// refresh only remembers.
    @Stored("seenInbox") var seenInbox: [String] = []
    @Stored("seenReady") var seenReady = false
    /// The user the seen entries belong to, so a key for another account starts over.
    @Stored("viewer") var seenViewer = ""
    var inbox: [InboxItem] = []
    var states: [String: [WorkflowState]] = [:]
    var viewerID: String?
    var searchProblem: String?
    var actionProblem: String?
    var commentDone: String?
    var problem: String?
    var loaded = false
    var formError: String?
    var created: String?

    static let fields = "id identifier title url branchName priority state { name type } team { id key }"
    static let inboxFields = "id type readAt createdAt actor { name } ... on IssueNotification { issue { identifier title url } }"

    // MARK: API

    func query<T: Decodable>(_ text: String, variables: [String: Any] = [:], as type: T.Type = T.self) async throws -> T {
        guard let key = try await Stackbar.secret("LINEAR_API_KEY"), !key.isEmpty else {
            throw HostError("Add your Linear API key (LINEAR_API_KEY) to see your issues")
        }
        let body = try JSONSerialization.data(withJSONObject: ["query": text, "variables": variables])
        let response = try await Stackbar.http(HTTPRequest(url: "https://api.linear.app/graphql", method: "POST", headers: [
            "Authorization": key, "Content-Type": "application/json",
        ], body: body, timeout: 15))
        guard response.status != 401 else { throw HostError("Linear rejected the API key (401); set a new LINEAR_API_KEY") }
        guard (200..<300).contains(response.status) || response.status == 400 else { throw HostError("Linear answered \(response.status)") }
        let reply = try JSONDecoder().decode(GraphQLReply<T>.self, from: response.body)
        if let data = reply.data { return data }
        throw HostError(reply.errors?.map(\.message).joined(separator: "; ") ?? "Linear sent no data")
    }

    /// When `refresh` last ran, so the palette views, which ask on every
    /// keystroke, can keep a recent list.
    var refreshed: Date?

    func refresh(maxAge: TimeInterval) async throws {
        if loaded, let at = refreshed, Date().timeIntervalSince(at) < (problem == nil ? maxAge : max(maxAge, 30)) { return }
        try await refresh()
    }

    /// The assigned issues after the first hundred, up to three more pages.
    func moreAssigned(after cursor: String) async throws -> [Issue] {
        struct Data: Decodable {
            struct Viewer: Decodable {
                struct Issues: Decodable {
                    struct Page: Decodable { let hasNextPage: Bool; let endCursor: String? }
                    let nodes: [Issue]
                    let pageInfo: Page
                }
                let assignedIssues: Issues
            }
            let viewer: Viewer
        }
        var all: [Issue] = []
        var after = cursor
        for _ in 0..<3 {
            let data = try await query("""
            query($after: String!) { viewer { assignedIssues(first: 100, after: $after, orderBy: updatedAt, filter: { state: { type: { nin: ["completed", "canceled"] } } }) { nodes { \(Self.fields) } pageInfo { hasNextPage endCursor } } } }
            """, variables: ["after": after], as: Data.self)
            all += data.viewer.assignedIssues.nodes
            guard data.viewer.assignedIssues.pageInfo.hasNextPage, let next = data.viewer.assignedIssues.pageInfo.endCursor else { break }
            after = next
        }
        return all
    }

    func refresh() async throws {
        refreshed = Date()
        struct Data: Decodable {
            struct Viewer: Decodable {
                struct Issues: Decodable {
                    struct Page: Decodable { let hasNextPage: Bool; let endCursor: String? }
                    let nodes: [Issue]
                    let pageInfo: Page
                }
                let id: String
                let assignedIssues: Issues
            }
            struct Teams: Decodable { let nodes: [Team] }
            struct Inbox: Decodable { let nodes: [InboxItem] }
            let viewer: Viewer
            let teams: Teams
            let notifications: Inbox
        }
        do {
            let data = try await query("""
            query { viewer { id assignedIssues(first: 100, orderBy: updatedAt, filter: { state: { type: { nin: ["completed", "canceled"] } } }) { nodes { \(Self.fields) } pageInfo { hasNextPage endCursor } } } \
            teams(first: 50) { nodes { id key name } } \
            notifications(first: 30) { nodes { \(Self.inboxFields) } } }
            """, as: Data.self)
            assigned = data.viewer.assignedIssues.nodes
            let page = data.viewer.assignedIssues.pageInfo
            if page.hasNextPage, let cursor = page.endCursor {
                // The rest is a bonus: a failure here keeps the first hundred.
                assigned += (try? await moreAssigned(after: cursor)) ?? []
            }
            viewerID = data.viewer.id
            if !seenViewer.isEmpty, seenViewer != data.viewer.id {
                seenReady = false; states = [:]; keyed = [:]; lookupMisses = [:]; lookupProblems = [:]; found = []; foundText = nil
            }
            if seenViewer != data.viewer.id { seenViewer = data.viewer.id }
            teams = data.teams.nodes
            // Archived and snoozed entries come back too; unread issue ones are the inbox.
            inbox = data.notifications.nodes.filter { $0.issue != nil }
            noticeInbox()
            problem = nil
        } catch {
            problem = "\(error)"
        }
        loaded = true
    }

    /// `ENG-123` or a pasted issue URL names one issue; anything else
    /// searches titles. A failure says why instead of an empty list.
    func search(_ text: String) async {
        let term = text.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2 else { found = []; searchProblem = nil; foundText = nil; return }
        if let identifier = Self.identifier(in: term) {
            foundText = nil
            await lookUp(identifier: identifier)
            found = keyed[identifier].map { [$0] } ?? []
            searchProblem = found.isEmpty ? (lookupProblems[identifier].map { "Couldn't look up \(identifier): \($0)" } ?? "No issue \(identifier)") : nil
            return
        }
        // Asked once typing pauses; retyping the text it last found asks nothing.
        if term == foundText, searchProblem == nil { return }
        try? await Task.sleep(for: .milliseconds(250))
        struct Data: Decodable { struct Issues: Decodable { let nodes: [Issue] }; let issues: Issues }
        do {
            let data = try await query("query($term: String!) { issues(first: 25, orderBy: updatedAt, filter: { title: { containsIgnoreCase: $term } }) { nodes { \(Self.fields) } } }", variables: ["term": term], as: Data.self)
            found = data.issues.nodes
            searchProblem = nil
            foundText = term
        } catch {
            found = []
            searchProblem = "\(error)"
            foundText = nil
        }
    }

    /// `ENG-123`, or the identifier in `https://linear.app/acme/issue/ENG-123/title`.
    static func identifier(in text: String) -> String? {
        let pattern = #"(?:^|/issue/)([A-Za-z][A-Za-z0-9]*-\d+)(?:$|[/?#])"#
        guard let match = text.range(of: pattern, options: .regularExpression) else { return nil }
        let piece = String(text[match])
        guard let id = piece.range(of: #"[A-Za-z][A-Za-z0-9]*-\d+"#, options: .regularExpression) else { return nil }
        let identifier = String(piece[id]).uppercased()
        // A bare word must be the whole text; a URL just has to contain it.
        return text.contains("/") || text.uppercased() == identifier ? identifier : nil
    }

    // MARK: Inbox

    var unread: [InboxItem] { inbox.filter { $0.readAt == nil } }

    func noticeInbox() {
        let ids = inbox.map(\.id)
        defer { seenInbox = ids; seenReady = true }
        guard seenReady, notifyInbox else { return }
        let known = Set(seenInbox)
        let fresh = unread.filter { !known.contains($0.id) }
        if fresh.count > 3 {
            Stackbar.notify("\(fresh.count) new in your Linear inbox", body: fresh.prefix(3).compactMap { $0.issue?.identifier }.joined(separator: ", ") + "…",
                            actions: [NotificationAction("Open Inbox", url: "https://linear.app/inbox")])
            return
        }
        for item in fresh {
            guard let issue = item.issue else { continue }
            Stackbar.notify("\(item.headline): \(issue.identifier)", body: issue.title, actions: [NotificationAction("Open", url: issue.url)])
        }
    }

    func markRead(_ item: InboxItem) async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        struct Done: Decodable { struct Payload: Decodable { let success: Bool }; let notificationUpdate: Payload }
        _ = try await query("mutation($id: String!, $at: DateTime!) { notificationUpdate(id: $id, input: { readAt: $at }) { success } }", variables: ["id": item.id, "at": now], as: Done.self)
        if let index = inbox.firstIndex(where: { $0.id == item.id }) {
            inbox[index] = InboxItem(id: item.id, type: item.type, readAt: now, createdAt: item.createdAt, actor: item.actor, issue: item.issue)
        }
    }

    /// What Mark All as Read asks before it runs: Stackbar holds the first press.
    var markAllConfirm: Confirm { "mark \(min(unread.count, 30)) as read" }

    /// Marks up to 30 unread inbox entries as read.
    func markAllRead() async {
        var done = 0
        for item in Array(unread.prefix(30)) {
            do {
                try await markRead(item)
                done += 1
            } catch {
                Stackbar.hud("Marked \(done), then: \(error)", isError: true)
                return
            }
        }
        Stackbar.hud("Marked \(done) as read")
    }

    func inboxRow(_ item: InboxItem) -> Row {
        let issue = item.issue
        let when = Self.date(item.createdAt).map { Self.ago($0) } ?? ""
        var row = Row(issue?.title ?? item.headline, subtitle: [item.headline, issue?.identifier, when].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "), symbol: item.symbol, key: "inbox-\(item.id)")
        if item.readAt == nil { row = row.badge("New", role: .accent) }
        return row
            .action("Open") {
                if let url = issue?.url { Stackbar.open(url) }
                do { try await self.markRead(item) } catch { Stackbar.hud("Couldn't mark as read: \(error)", isError: true) }
            }
            .action("Mark as Read", shortcut: "cmd+r") { try await self.markRead(item) }
            .action("Copy ID", shortcut: "cmd+shift+c") { if let id = issue?.identifier { Stackbar.copy(id) } }
    }

    static let fractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    static let plainStyle = Date.ISO8601FormatStyle()
    /// Linear's timestamps carry milliseconds (`2026-11-03T10:15:30.123Z`),
    /// which the default formatter rejects; plain ones are accepted too.
    static func date(_ text: String) -> Date? {
        (try? fractionalStyle.parse(text)) ?? (try? plainStyle.parse(text))
    }

    static func ago(_ date: Date) -> String {
        let minutes = Int(-date.timeIntervalSinceNow / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 60 * 24 { return "\(minutes / 60)h" }
        return "\(minutes / 60 / 24)d"
    }

    // MARK: Actions

    func update(_ issue: Issue, _ input: [String: Any], done: String) async {
        struct Done: Decodable { struct Payload: Decodable { let success: Bool }; let issueUpdate: Payload }
        do {
            _ = try await query("mutation($id: String!, $input: IssueUpdateInput!) { issueUpdate(id: $id, input: $input) { success } }", variables: ["id": issue.id, "input": input], as: Done.self)
            Stackbar.hud(done)
            try await refresh()
        } catch {
            Stackbar.hud("\(error)", isError: true)
        }
    }

    func myID() async throws -> String {
        if let viewerID { return viewerID }
        struct Viewer: Decodable { struct Me: Decodable { let id: String }; let viewer: Me }
        let id = try await query("query { viewer { id } }", as: Viewer.self).viewer.id
        viewerID = id
        return id
    }

    /// The team's workflow, in Linear's order.
    func loadStates(team: String) async {
        guard states[team] == nil else { return }
        struct Data: Decodable { struct Team: Decodable { struct States: Decodable { let nodes: [WorkflowState] }; let states: States }; let team: Team }
        do {
            states[team] = try await query("query($id: String!) { team(id: $id) { states { nodes { id name type position } } } }", variables: ["id": team], as: Data.self)
                .team.states.nodes.sorted { (Self.typeOrder($0.type), $0.position) < (Self.typeOrder($1.type), $1.position) }
            actionProblem = nil
        } catch {
            actionProblem = "\(error)"
        }
    }

    static func typeOrder(_ type: String) -> Int {
        ["triage", "backlog", "unstarted", "started", "completed", "canceled"].firstIndex(of: type) ?? 9
    }

    /// In Progress (the team's first started state), assigned to you, and the
    /// branch name on the clipboard: everything before `git switch -c`.
    func startWork(_ issue: Issue) async throws {
        do {
            guard let team = issue.team.id else { throw HostError("Linear didn't say which team \(issue.identifier) is in") }
            await loadStates(team: team)
            var input: [String: Any] = ["assigneeId": try await myID()]
            if issue.state.type != "started", let started = states[team]?.first(where: { $0.type == "started" }) { input["stateId"] = started.id }
            Stackbar.copy(issue.branchName)
            await update(issue, input, done: "Started \(issue.identifier) · branch name copied")
        } catch {
            Stackbar.hud("\(error)", isError: true)
        }
    }

    func comment(on issue: Issue, _ text: String) async throws {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { actionProblem = "Write a comment first"; return }
        struct Done: Decodable { struct Payload: Decodable { let success: Bool }; let commentCreate: Payload }
        do {
            _ = try await query("mutation($input: CommentCreateInput!) { commentCreate(input: $input) { success } }", variables: ["input": ["issueId": issue.id, "body": body]], as: Done.self)
            actionProblem = nil
            commentDone = "Comment added to \(issue.identifier)"
            Stackbar.hud("Comment added to \(issue.identifier)")
        } catch {
            actionProblem = "\(error)"
        }
    }

    /// The issue a status, priority or comment view acts on: one you can see,
    /// else fetched by identifier.
    func issue(_ identifier: String?) async -> Issue? {
        guard let identifier = identifier?.trimmingCharacters(in: .whitespaces).uppercased(), !identifier.isEmpty else { return nil }
        if let known = (assigned + found).first(where: { $0.identifier == identifier }) ?? keyed[identifier] { return known }
        guard Self.isIdentifier(identifier) else { return nil }
        await lookUp(identifier: identifier)
        return keyed[identifier]
    }

    func known(_ identifier: String?) -> Issue? {
        guard let identifier = identifier?.trimmingCharacters(in: .whitespaces).uppercased() else { return nil }
        return (assigned + found).first { $0.identifier == identifier } ?? keyed[identifier]
    }

    /// Looks up one issue by identifier (ENG-231) for the palette's root:
    /// from your assigned issues when it is there, else one request.
    func lookUp(identifier text: String) async {
        let identifier = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard keyed[identifier] == nil else { return }
        if let mine = assigned.first(where: { $0.identifier == identifier }) {
            keyed[identifier] = mine
            return
        }
        struct Data: Decodable { let issue: Issue? }
        // An identifier that wasn't found, or a lookup that failed, isn't
        // asked again for a minute: the views ask on every keystroke.
        if let at = lookupMisses[identifier], Date().timeIntervalSince(at) < 60 { return }
        do {
            if let issue = try await query("query($id: String!) { issue(id: $id) { \(Self.fields) } }", variables: ["id": identifier], as: Data.self).issue {
                if keyed.count >= 100 { keyed.removeAll() }
                keyed[identifier] = issue
                lookupProblems[identifier] = nil
            } else {
                lookupMisses[identifier] = Date()
                lookupProblems[identifier] = nil
            }
        } catch {
            lookupMisses[identifier] = Date()
            lookupProblems[identifier] = "\(error)"
        }
        if lookupMisses.count >= 100 {
            lookupMisses = lookupMisses.filter { Date().timeIntervalSince($0.value) < 60 }
            lookupProblems = lookupProblems.filter { lookupMisses[$0.key] != nil }
        }
    }

    /// Whether `text` is a whole identifier (`ENG-123`), not the start of one.
    static func isIdentifier(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z][A-Za-z0-9]*-\d+$"#, options: .regularExpression) != nil
    }

    // MARK: Grouping

    /// started, unstarted, backlog, triage: the order Linear's own My Issues uses.
    static let stateOrder = ["started", "unstarted", "triage", "backlog"]

    var groups: [(state: String, issues: [Issue])] {
        let byState = Dictionary(grouping: assigned) { $0.state.name }
        return byState.map { (state: $0.key, issues: $0.value.sorted { (Self.rank($0.priority), $0.identifier) < (Self.rank($1.priority), $1.identifier) }) }
            .sorted { lhs, rhs in
                let left = Self.stateOrder.firstIndex(of: lhs.issues[0].state.type) ?? 9
                let right = Self.stateOrder.firstIndex(of: rhs.issues[0].state.type) ?? 9
                return (left, lhs.state) < (right, rhs.state)
            }
    }

    /// Linear's priority 0 is "none"; 1 (urgent) sorts first.
    static func rank(_ priority: Double) -> Double { priority == 0 ? 5 : priority }

    static func priorityName(_ priority: Double) -> String? {
        switch Int(priority) {
        case 1: return "Urgent"
        case 2: return "High"
        case 3: return "Medium"
        case 4: return "Low"
        default: return nil
        }
    }

    var inProgress: [Issue] { assigned.filter { $0.state.type == "started" } }

    func row(_ issue: Issue) -> Row {
        var row = Row(issue.title, subtitle: "\(issue.identifier) · \(issue.state.name)", symbol: Self.symbol(issue.state.type), key: issue.id)
        if issue.priority == 1 || issue.priority == 2, let priority = Self.priorityName(issue.priority) {
            row = row.badge(priority, role: issue.priority == 1 ? .critical : .warning)
        }
        return row
            .action("Open") { Stackbar.open(issue.url) }
            .action("Start Work", shortcut: "cmd+return") { try await self.startWork(issue) }
            .navigate("Change Status…", to: "status", arguments: ["issue": issue.identifier], shortcut: "cmd+s")
            .navigate("Set Priority…", to: "priority", arguments: ["issue": issue.identifier], shortcut: "cmd+p")
            .navigate("Comment…", to: "comment", arguments: ["issue": issue.identifier], shortcut: "cmd+k")
            .action("Copy Branch Name", shortcut: "cmd+shift+b") { Stackbar.copy(issue.branchName) }
            .action("Copy Link", shortcut: "cmd+c") { Stackbar.copy(issue.url) }
            .action("Copy ID", shortcut: "cmd+shift+c") { Stackbar.copy(issue.identifier) }
    }

    // MARK: Surfaces

    static func symbol(_ type: String) -> String {
        switch type {
        case "started": return "circle.lefthalf.filled"
        case "backlog": return "circle.dotted"
        case "triage": return "exclamationmark.circle"
        default: return "circle"
        }
    }

    let theme = Theme.indigo
    var urgent: Int { assigned.filter { $0.priority == 1 }.count }
    /// No API key yet: a setup prompt, not a failure.
    var needsKey: Bool { (problem?.contains("LINEAR_API_KEY") ?? false) && !(problem?.contains("401") ?? false) }

    /// In progress first, then the rest assigned; a click opens the issue.
    var widget: ViewContent {
        if needsKey {
            EmptyState("Connect Linear", symbol: "key.fill", message: "Add your Linear API key in Stackbar.", theme: theme)
        } else {
            PanelHeader(inProgress.isEmpty ? "\(assigned.count) assigned" : "\(inProgress.count) in progress", subtitle: "Linear", symbol: "checklist", theme: theme)
            if assigned.isEmpty {
                EmptyState(problem == nil ? "Nothing assigned" : "Can't reach Linear", symbol: "checkmark.circle", theme: theme)
            } else {
                List(inProgress + assigned.filter { $0.state.type != "started" }) { issue in self.row(issue) }
            }
        }
    }

    var menuBar: ViewContent {
        let count = menuBarCount == "All assigned" ? assigned.count : inProgress.count
        if needsKey {
            Label("", symbol: "checklist").role(.secondary)
        } else if problem != nil, loaded {
            Label("", symbol: "checklist").role(.warning)
        } else if !unread.isEmpty {
            Label("\(unread.count)", symbol: "bell.badge.fill").role(.warning)
        } else if count == 0 {
            Label("", symbol: "checklist").role(.secondary)
        } else {
            Label("\(count)", symbol: "checklist").role(urgent > 0 ? .warning : .primary)
        }
    }

    var panel: ViewContent {
        VStack(spacing: Space.m) {
            if !loaded {
                PanelHeader("Linear", subtitle: "Checking…", symbol: "checklist", theme: theme)
            } else if let problem, assigned.isEmpty {
                if needsKey {
                    EmptyState("Connect Linear", symbol: "key.fill", message: "Create a personal API key in Linear under Settings > Security & access. Stackbar asks for it once and keeps it in your Keychain.", theme: theme) {
                        ActionButton("Add API Key", symbol: "key.fill", theme: theme, prominent: true) { try await self.refresh() }
                    }
                } else {
                    EmptyState("Can't reach Linear", symbol: "exclamationmark.triangle.fill", message: problem, theme: .critical) {
                        ActionButton("Try Again", symbol: "arrow.clockwise", theme: theme) { try await self.refresh() }
                    }
                }
            } else {
                PanelHeader(inProgress.isEmpty ? (assigned.isEmpty ? "Nothing assigned" : "Nothing in progress") : "\(inProgress.count) in progress", subtitle: "\(assigned.count) assigned" + (urgent > 0 ? " · \(urgent) urgent" : ""), symbol: "checklist", theme: theme)
                if !assigned.isEmpty {
                    HeroCard(theme: theme, look: .glow) {
                        HStack(spacing: Space.l) {
                            HeroStat("In progress", value: "\(inProgress.count)", theme: theme, live: !inProgress.isEmpty)
                            HeroStat("Assigned", value: "\(assigned.count)", theme: .neutral, symbol: "tray.full.fill")
                            HeroStat("Urgent", value: "\(urgent)", theme: urgent > 0 ? .critical : .neutral, symbol: "exclamationmark.square.fill")
                            Spacer()
                        }
                    }
                }
                if let problem { Banner(problem) }
                if !unread.isEmpty {
                    Section("Inbox · \(unread.count) new") {
                        ActionButton("Mark All as Read", symbol: "checkmark.circle", theme: theme, key: "inbox-mark-all", confirm: markAllConfirm) { await self.markAllRead() }
                        ForEach(Array(unread.prefix(5))) { item in self.inboxRow(item) }
                    }
                }
                if assigned.isEmpty {
                    EmptyState("Nothing assigned to you", symbol: "checkmark", theme: .success)
                } else {
                    VStack(spacing: Space.s) {
                        ForEach(groups) { group in
                            Section("\(group.state) · \(group.issues.count)") {
                                ForEach(group.issues) { issue in self.row(issue) }
                            }
                        }
                    }
                }
            }
        }
    }

    var settings: ViewContent {
        Section("Menu bar") {
            Picker("Count", options: ["In progress", "All assigned"], selection: menuBarCount, style: .segmented) { self.menuBarCount = $0 }
        }
        Section("Notifications") {
            Toggle("Notify when something new reaches my inbox", isOn: notifyInbox) { self.notifyInbox = $0 }
            Text("Assignments, mentions and comments, as Linear's own inbox lists them. The menu bar shows a bell while any are unread.").style(.caption)
        }
        Section("New issues") {
            if teams.isEmpty {
                Text("Teams appear once your API key works.").style(.caption)
            } else {
                Picker("Default team", options: teams.map(\.name), selection: teams.first { $0.id == defaultTeam }?.name ?? teams[0].name) { name in
                    self.defaultTeam = self.teams.first { $0.name == name }?.id ?? ""
                }
            }
        }
        Section("API key") {
            Text("Create a personal API key in Linear (Settings > Security & access). Stackbar asks for it the first time and keeps it in your Keychain as LINEAR_API_KEY.").style(.caption)
            if let problem { Text(problem).role(.warning).style(.caption) }
        }
    }

    // MARK: Commands

    var commands: [Command] {
        Command("my-issues", title: "My Linear Issues", symbol: "checklist", keywords: ["linear", "issue", "assigned", "ticket"])
            .view(search: { _ in try await self.refresh(maxAge: 30) }) { _ in
                if let problem = self.problem {
                    ContentUnavailableView("Can't reach Linear", symbol: "exclamationmark.triangle", message: problem)
                } else {
                    List(self.assigned, searchable: true) { issue in self.row(issue) }
                }
            }
        Command("search", title: "Search Linear Issues", symbol: "magnifyingglass", keywords: ["linear", "issue", "find"])
            .view(search: { invocation in await self.search(invocation.text) }) { invocation in
                if invocation.text.trimmingCharacters(in: .whitespaces).count < 2 {
                    ContentUnavailableView("Type to search titles, or paste an ID or link", symbol: "magnifyingglass")
                } else if let problem = self.searchProblem, self.found.isEmpty {
                    ContentUnavailableView("Can't search Linear", symbol: "exclamationmark.triangle", message: problem)
                } else if self.found.isEmpty {
                    ContentUnavailableView("No issues match", symbol: "magnifyingglass")
                } else {
                    List(self.found) { issue in self.row(issue) }
                }
            }
        Command("inbox", title: "Linear Inbox", symbol: "tray", keywords: ["linear", "notifications", "mentions", "inbox"])
            .view(search: { _ in try await self.refresh(maxAge: 30) }) { _ in
                if let problem = self.problem, self.inbox.isEmpty {
                    ContentUnavailableView("Can't reach Linear", symbol: "exclamationmark.triangle", message: problem)
                } else if self.inbox.isEmpty {
                    ContentUnavailableView("Inbox zero", symbol: "tray")
                } else {
                    List(searchable: true) {
                        ForEach(self.inbox) { item in self.inboxRow(item) }
                        if !self.unread.isEmpty {
                            Row("Mark All as Read", symbol: "checkmark.circle", key: "inbox-mark-all")
                                .action("Mark All as Read", confirm: self.markAllConfirm) { await self.markAllRead() }
                        }
                    }
                }
            }
        Command("status", title: "Change Linear Issue Status", symbol: "arrow.triangle.swap", keywords: ["linear", "state", "move", "done"])
            .argument("issue", placeholder: "ENG-123")
            .view(search: { invocation in
                if let issue = await self.issue(invocation["issue"]), let team = issue.team.id { await self.loadStates(team: team) }
            }) { invocation in
                if let issue = self.known(invocation["issue"]), let team = issue.team.id {
                    if let problem = self.actionProblem, self.states[team] == nil {
                        ContentUnavailableView("Can't load the workflow", symbol: "exclamationmark.triangle", message: problem)
                    } else {
                        List(self.states[team] ?? [], searchable: true) { state in
                            Row(state.name, subtitle: state.name == issue.state.name ? "Current · \(issue.identifier)" : issue.identifier, symbol: Self.symbol(state.type), key: state.id)
                                .action("Move to \(state.name)") { await self.update(issue, ["stateId": state.id], done: "\(issue.identifier) moved to \(state.name)") }
                        }
                    }
                } else {
                    ContentUnavailableView("Which issue?", symbol: "checklist", message: "Type its ID, like ENG-123.")
                }
            }
            .stackbarOnly()
        Command("priority", title: "Set Linear Issue Priority", symbol: "exclamationmark.square", keywords: ["linear", "priority", "urgent"])
            .argument("issue", placeholder: "ENG-123")
            .view(search: { invocation in _ = await self.issue(invocation["issue"]) }) { invocation in
                if let issue = self.known(invocation["issue"]) {
                    List(Array(["No priority", "Urgent", "High", "Medium", "Low"].enumerated()).map { PriorityChoice(id: $0.offset, name: $0.element) }) { choice in
                        Row(choice.name, subtitle: Int(issue.priority) == choice.id ? "Current · \(issue.identifier)" : issue.identifier,
                            symbol: choice.id == 1 ? "exclamationmark.square.fill" : choice.id == 0 ? "minus" : "chart.bar.fill", key: "p\(choice.id)")
                            .action("Set \(choice.name)") { await self.update(issue, ["priority": choice.id], done: "\(issue.identifier): \(choice.name)") }
                    }
                } else {
                    ContentUnavailableView("Which issue?", symbol: "checklist", message: "Type its ID, like ENG-123.")
                }
            }
            .stackbarOnly()
        Command("comment", title: "Comment on Linear Issue", symbol: "text.bubble", keywords: ["linear", "comment", "reply"])
            .argument("issue", placeholder: "ENG-123")
            .view(search: { invocation in _ = await self.issue(invocation["issue"]) }) { invocation in
                if let issue = self.known(invocation["issue"]) {
                    Form(submit: "Add Comment", key: "comment-\(issue.identifier)") {
                        FormField.multiline("Comment on \(issue.identifier)", name: "body", placeholder: "Markdown")
                    } onSubmit: { values in
                        try await self.comment(on: issue, values.string("body") ?? "")
                    }
                    if let problem = self.actionProblem { Banner(problem) }
                    if let done = self.commentDone { Banner(done, symbol: "checkmark.circle.fill", theme: .success) }
                } else {
                    ContentUnavailableView("Which issue?", symbol: "checklist", message: "Type its ID, like ENG-123.")
                }
            }
            .stackbarOnly()
        // An identifier typed at the palette's root opens that issue.
        Command("issue", title: "Linear Issue by ID", symbol: "checklist", keywords: ["linear"])
            .view(search: { invocation in await self.lookUp(identifier: invocation.text) }) { invocation in
                List(self.keyed[invocation.text.trimmingCharacters(in: .whitespaces).uppercased()].map { [$0] } ?? []) { issue in self.row(issue) }
            }
            .rootSearch(section: "Linear", matching: #"[A-Za-z][A-Za-z0-9]*-\d+"#)
            .stackbarOnly()
        // `create Fix the login page` (or a link with ?title=) starts the
        // form with the title filled in.
        Command("create", title: "Create Linear Issue", symbol: "plus.circle", keywords: ["linear", "issue", "new", "ticket"])
            .argument("title", placeholder: "Title", required: false)
            .view { invocation in self.form(title: invocation["title"] ?? "") }
    }

    @ViewBuilder func form(title: String = "") -> ViewContent {
        if teams.isEmpty {
            ContentUnavailableView("No teams yet", symbol: "person.3", message: problem ?? "Add your Linear API key, then try again.")
        } else {
            Form(submit: "Create Issue", key: "issue") {
                FormField.picker("Team", name: "team", options: teams.map(\.name), selection: teams.first { $0.id == defaultTeam }?.name ?? teams[0].name)
                FormField.text("Title", name: "title", value: title, error: formError)
                FormField.multiline("Description", name: "description", placeholder: "Markdown")
                FormField.picker("Priority", name: "priority", options: ["No priority", "Urgent", "High", "Medium", "Low"], selection: "No priority")
                FormField.toggle("Assign to me", name: "mine", isOn: true)
            } onSubmit: { values in
                try await self.create(values)
            }
            if let created { Banner(created, symbol: "checkmark.circle.fill", theme: .success) }
        }
    }

    func create(_ values: [String: EventValue]) async throws {
        let title = (values.string("title") ?? "").trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { formError = "Give it a title"; return }
        guard let team = teams.first(where: { $0.name == values.string("team") }) ?? teams.first else { formError = "Pick a team"; return }
        formError = nil
        var input: [String: Any] = ["teamId": team.id, "title": title]
        if let description = values.string("description"), !description.isEmpty { input["description"] = description }
        if let index = ["No priority", "Urgent", "High", "Medium", "Low"].firstIndex(of: values.string("priority") ?? "") { input["priority"] = index }
        struct Viewer: Decodable { struct Me: Decodable { let id: String }; let viewer: Me }
        if case .bool(true)? = values["mine"] {
            input["assigneeId"] = try await query("query { viewer { id } }", as: Viewer.self).viewer.id
        }
        struct Created: Decodable {
            struct Payload: Decodable { struct Made: Decodable { let identifier: String; let url: String }; let success: Bool; let issue: Made? }
            let issueCreate: Payload
        }
        do {
            let reply = try await query("mutation($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { identifier url } } }", variables: ["input": input], as: Created.self)
            guard let issue = reply.issueCreate.issue else { formError = "Linear didn't create it"; return }
            created = "Created \(issue.identifier) · link copied"
            Stackbar.copy(issue.url)
            try await refresh()
        } catch {
            formError = "\(error)"
        }
    }

    struct PriorityChoice: Identifiable { let id: Int; let name: String }

    var tools: [AgentTool] {
        AgentTool("assigned", description: "Open Linear issues assigned to the user, with identifier, state, priority, title and branch name") { _ in
            if !self.loaded { try await self.refresh() }
            if let problem = self.problem { return problem }
            return self.assigned.map { "\($0.identifier)\t\($0.state.name)\t\(Self.priorityName($0.priority) ?? "-")\t\($0.title)\t\($0.branchName)" }.joined(separator: "\n")
        }
    }
}
