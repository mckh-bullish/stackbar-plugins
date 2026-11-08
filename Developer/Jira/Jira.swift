import StackbarKit
import Foundation

/// Your Jira Cloud issues in the menu bar and the palette: what's assigned
/// to you, search by text or key, and new issues without opening Jira.
///
/// It signs in to your site (`yourteam.atlassian.net`) with your email and
/// an API token from id.atlassian.com, kept in your Keychain as
/// `JIRA_API_TOKEN`. Requests go only to `*.atlassian.net`, or, for Jira Data
/// Center, to the server you enter as `JIRA_SERVER_URL` with a personal
/// access token.
@main
final class Jira: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.jira",
        name: "Jira",
        version: "1.6.0",
        summary: "Your assigned Jira issues: change status, assign, comment and watch, with alerts and new issues from the palette.",
        surfaces: [.menuBar, .panel, .widget, .settings],
        triggers: [.launch, .minutes(5), .wake],
        capabilities: [.network("*.atlassian.net"), .secret(name: "JIRA_API_TOKEN"), .userServer(secret: "JIRA_SERVER_URL")],
        minimumStackbar: "0.22.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Developer/Jira",
        accent: .blue,
        symbol: "ticket.fill"
    )

    // MARK: Previews

    static let previews: [PreviewScene<Jira>] = [
        PreviewScene("hero", "Your issues, grouped by where they stand") { plugin in
            plugin.site = "acme.atlassian.net"
            plugin.email = "sam@example.com"
            plugin.projects = [Project(id: "10001", key: "SHOP", name: "Shop"), Project(id: "10002", key: "APP", name: "Mobile App")]
            plugin.defaultProject = "SHOP"
            plugin.assigned = samples
            plugin.doneThisWeek = [
                sample("SHOP-398", "Cache product images at the edge", "Done", "done", "Medium", "Task"),
                sample("SHOP-401", "Fix VAT rounding on invoices", "Done", "done", "High", "Bug"),
                sample("APP-77", "Dark mode for the order screen", "Done", "done", "Low", "Story"),
            ]
            plugin.loaded = true
        },
        PreviewScene("widget", "What you're on, on your desktop", surface: .widget) { plugin in
            plugin.site = "acme.atlassian.net"
            plugin.email = "sam@example.com"
            plugin.assigned = samples
            plugin.loaded = true
        },
    ]

    static func sample(_ key: String, _ summary: String, _ status: String, _ category: String, _ priority: String, _ type: String) -> Issue {
        let project = key.hasPrefix("APP") ? Issue.Fields.Project(key: "APP", name: "Mobile App") : Issue.Fields.Project(key: "SHOP", name: "Shop")
        return Issue(id: key, key: key, fields: Issue.Fields(summary: summary, status: .init(name: status, statusCategory: .init(key: category)),
                                                            priority: .init(name: priority), issuetype: .init(name: type), project: project))
    }

    static let samples = [
        sample("SHOP-412", "Checkout fails when the coupon field is empty", "In Progress", "indeterminate", "Highest", "Bug"),
        sample("SHOP-409", "Add Apple Pay to the checkout", "In Review", "indeterminate", "High", "Story"),
        sample("APP-81", "Push notification when an order ships", "In Progress", "indeterminate", "Medium", "Story"),
        sample("SHOP-415", "Search results ignore the size filter", "To Do", "new", "High", "Bug"),
        sample("SHOP-420", "Show delivery estimates on product pages", "To Do", "new", "Medium", "Story"),
        sample("APP-84", "Upgrade to the new payments SDK", "To Do", "new", "Low", "Task"),
    ]

    struct Issue: Decodable, Equatable, Identifiable {
        struct Fields: Decodable, Equatable {
            struct Named: Decodable, Equatable { let name: String }
            struct Status: Decodable, Equatable {
                struct Category: Decodable, Equatable { let key: String }
                let name: String
                let statusCategory: Category?
            }
            struct Project: Decodable, Equatable { let key: String; let name: String }
            let summary: String
            let status: Status?
            let priority: Named?
            let issuetype: Named?
            let project: Project?
        }
        let id: String
        let key: String
        let fields: Fields
        /// new, indeterminate (in progress) or done.
        var category: String { fields.status?.statusCategory?.key ?? "new" }
    }

    struct Transition: Decodable, Equatable, Identifiable {
        struct Target: Decodable, Equatable {
            struct Category: Decodable, Equatable { let key: String }
            let name: String
            let statusCategory: Category?
        }
        let id: String
        let name: String
        let to: Target?
    }

    struct Project: Codable, Equatable, Identifiable {
        let id: String
        let key: String
        let name: String
    }

    @Stored("site") var site = ""
    @Stored("email") var email = ""
    @Stored("projects") var projects: [Project] = []
    @Stored("defaultProject") var defaultProject = ""
    @Stored("jql") var jql = Jira.defaultJQL
    /// "Cloud" or "Data Center".
    @Stored("deployment") var deployment = "Cloud"
    @Stored("notify") var notifyOnAssign = true
    /// Keys of the issues already assigned, so only new ones notify. Empty
    /// until the first good refresh, which notifies nothing.
    @Stored("seen") var seen: [String] = []
    @Stored("seenReady") var seenReady = false
    /// The site and user the seen keys belong to, so a switch to another
    /// account starts over instead of announcing its whole list as new.
    @Stored("account") var account = ""
    /// The Data Center server's base URL, read from JIRA_SERVER_URL.
    var server: String?
    /// The signed-in user: accountId on Cloud, the username on Data Center.
    var me: String?
    /// The server and token the last request used; a change means another account.
    var credentials: String?
    /// Workflow transitions of an issue, by key, for the status command.
    var transitions: [String: [Transition]] = [:]
    /// When each issue's transitions were loaded: a workflow changed by
    /// someone else shows up again after `transitionsTTL`.
    var transitionsLoadedAt: [String: Date] = [:]
    static let transitionsTTL: TimeInterval = 60
    var actionProblem: String?
    var commentDone: String?
    var assigned: [Issue] = []
    /// The issue an issue key typed at the palette's root names.
    var keyed: [String: Issue] = [:]
    /// When each key that wasn't found (or failed to load) was last asked for.
    var keyMisses: [String: Date] = [:]
    var keyProblem: String?
    var found: [Issue] = []
    /// The text `found` answers, so typing it again asks Jira nothing.
    var foundText: String?
    /// Why the last search failed, shown instead of an empty list.
    var searchProblem: String?
    /// Your issues that moved to Done in the last week. The panel JQL leaves
    /// Done out by default, so this is a query of its own.
    var doneThisWeek: [Issue] = []
    var problem: String?
    var loaded = false
    /// When the projects were last listed, so ones created since show up.
    var projectsLoaded: Date?
    var formError: String?
    var created: String?

    static let defaultJQL = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"
    static let doneJQL = "assignee = currentUser() AND statusCategory = Done AND statusCategoryChangedDate >= -7d ORDER BY updated DESC"
    static let fields = ["summary", "status", "priority", "issuetype", "project"]

    /// `yourteam`, `yourteam.atlassian.net` or a pasted URL, as the host.
    static func host(of site: String) -> String? {
        var text = site.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        text = String(text.prefix { $0 != "/" })
        guard !text.isEmpty, text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }) else { return nil }
        return text.hasSuffix(".atlassian.net") ? text : text + ".atlassian.net"
    }

    var isDataCenter: Bool { deployment == "Data Center" }
    /// Cloud speaks REST v3 (rich text in Atlassian Document Format); Data
    /// Center speaks v2 (plain text).
    var apiVersion: String { isDataCenter ? "2" : "3" }

    /// Where the site is: the Cloud host, or the Data Center server.
    var base: String {
        if isDataCenter { return server.map(Self.trimmed) ?? "" }
        return "https://\(Self.host(of: site) ?? "")"
    }

    static func trimmed(_ url: String) -> String {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    func url(for issue: Issue) -> String { "\(base)/browse/\(issue.key)" }
    func url(key: String) -> String { "\(base)/browse/\(key)" }

    // MARK: API

    /// `path` starts after the API version: `/search`, `/issue/ABC-1`.
    func api(_ path: String, method: String = "GET", body: Any? = nil) async throws -> Data {
        let authorization: String
        let where_: String
        if isDataCenter {
            if server == nil { server = try await Stackbar.secret("JIRA_SERVER_URL").map(Self.trimmed).flatMap { $0.isEmpty ? nil : $0 } }
            guard let server else { throw HostError("Enter your Jira server's URL as JIRA_SERVER_URL") }
            guard let token = try await Stackbar.secret("JIRA_API_TOKEN"), !token.isEmpty else {
                throw HostError("Add a personal access token from your Jira profile as JIRA_API_TOKEN")
            }
            authorization = "Bearer \(token)"
            where_ = server
        } else {
            guard let host = Self.host(of: site), !email.isEmpty else {
                throw HostError("Set your Jira site and email in Settings")
            }
            guard let token = try await Stackbar.secret("JIRA_API_TOKEN"), !token.isEmpty else {
                throw HostError("Add your Jira API token (JIRA_API_TOKEN) from id.atlassian.com")
            }
            authorization = "Basic " + Data("\(email):\(token)".utf8).base64EncodedString()
            where_ = "https://\(host)"
        }
        let current = authorization + "|" + where_
        if let credentials, credentials != current {
            me = nil; transitions = [:]; transitionsLoadedAt = [:]; keyed = [:]; keyMisses = [:]; projects = []; found = []; foundText = nil
        }
        credentials = current
        let host = URL(string: where_)?.host ?? where_
        let response = try await Stackbar.http(HTTPRequest(url: "\(where_)/rest/api/\(apiVersion)\(path)", method: method, headers: [
            "Authorization": authorization, "Accept": "application/json", "Content-Type": "application/json",
        ], body: try body.map { try JSONSerialization.data(withJSONObject: $0, options: .fragmentsAllowed) }, timeout: 15))
        switch response.status {
        case 200..<300: return response.body
        case 401: throw HostError(isDataCenter ? "Jira rejected the access token (401)" : "Jira rejected the email or API token (401)")
        case 403: throw HostError("Jira says this account can't do that (403)")
        case 404: throw HostError("Jira didn't find that on \(host) (404)")
        default:
            struct Failure: Decodable { let errorMessages: [String]?; let errors: [String: String]? }
            let failure = try? JSONDecoder().decode(Failure.self, from: response.body)
            let messages = (failure?.errorMessages ?? []) + (failure?.errors.map { $0.map { "\($0.key): \($0.value)" } } ?? [])
            throw HostError("Jira answered \(response.status)" + (messages.isEmpty ? "" : ": " + messages.joined(separator: "; ")))
        }
    }

    func search(jql: String, limit: Int = 50) async throws -> [Issue] {
        struct Reply: Decodable { let issues: [Issue] }
        let data = try await api(isDataCenter ? "/search" : "/search/jql", method: "POST", body: ["jql": jql, "fields": Self.fields, "maxResults": limit] as [String: Any])
        return try JSONDecoder().decode(Reply.self, from: data).issues
    }

    /// Up to `cap` issues for `jql`, a page of 50 at a time. Cloud pages by
    /// token, Data Center by offset.
    func searchAll(jql: String, cap: Int = 200) async throws -> [Issue] {
        struct Page: Decodable {
            let issues: [Issue]
            let nextPageToken: String?
            let total: Int?
        }
        var all: [Issue] = []
        var token: String?
        while all.count < cap {
            var body: [String: Any] = ["jql": jql, "fields": Self.fields, "maxResults": min(50, cap - all.count)]
            if isDataCenter { body["startAt"] = all.count } else if let token { body["nextPageToken"] = token }
            let page = try JSONDecoder().decode(Page.self, from: try await api(isDataCenter ? "/search" : "/search/jql", method: "POST", body: body))
            all += page.issues
            if page.issues.isEmpty { break }
            if isDataCenter {
                if let total = page.total, all.count >= total { break }
                if page.total == nil, page.issues.count < 50 { break }
            } else {
                guard let next = page.nextPageToken, !next.isEmpty else { break }
                token = next
            }
        }
        return all
    }

    /// When `refresh` last ran, so the palette view, which asks on every
    /// keystroke, can keep a recent list.
    var refreshed: Date?

    func refresh(maxAge: TimeInterval) async throws {
        if loaded, let at = refreshed, Date().timeIntervalSince(at) < (problem == nil ? maxAge : max(maxAge, 30)) { return }
        try await refresh()
    }

    func refresh() async throws {
        refreshed = Date()
        guard !needsSetup else {
            problem = "Set your Jira site and email in Settings"
            loaded = true
            return
        }
        do {
            assigned = try await searchAll(jql: jql)
            // Without a user (a failed lookup), keep the account as it was.
            if let user = try? await myself() {
                let who = base + "|" + user
                if !account.isEmpty, account != who { seenReady = false }
                if account != who { account = who }
            }
            noticeNewAssignments()
            // Only a stat, so a site that rejects this query keeps the rest of the panel.
            doneThisWeek = (try? await searchAll(jql: Self.doneJQL)) ?? []
            if projects.isEmpty {
                try await loadProjects()
                projectsLoaded = Date()
            } else if projectsLoaded.map({ Date().timeIntervalSince($0) > 3600 }) ?? true {
                try? await loadProjects()
                projectsLoaded = Date()
            }
            problem = nil
        } catch {
            problem = "\(error)"
        }
        loaded = true
    }

    func loadProjects() async throws {
        struct Reply: Decodable { let values: [Project] }
        if isDataCenter {
            // Data Center lists every project in one array.
            projects = Array(try JSONDecoder().decode([Project].self, from: try await api("/project")).prefix(50))
        } else {
            let data = try await api("/project/search?maxResults=50&orderBy=-lastIssueUpdatedTime")
            projects = try JSONDecoder().decode(Reply.self, from: data).values
        }
    }

    /// A key or a pasted issue link opens that issue; anything else is a text
    /// search. The search waits for a pause in typing, and retyping the text
    /// it last found asks Jira nothing.
    func find(_ text: String) async {
        let term = text.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2 else { found = []; searchProblem = nil; foundText = nil; return }
        if term == foundText, searchProblem == nil { return }
        try? await Task.sleep(for: .milliseconds(250))
        let escaped = term.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let query: String
        if let key = Self.key(in: term) { query = "key = \"\(key)\"" } else { query = "text ~ \"\(escaped)\" ORDER BY updated DESC" }
        do {
            found = try await search(jql: query, limit: 25)
            searchProblem = nil
            foundText = term
        } catch {
            found = []
            searchProblem = "\(error)"
            foundText = nil
        }
    }

    /// Looks up one issue by key for the palette's root: from your assigned
    /// issues when it is there, else one request. Unknown keys show nothing.
    func lookUp(key text: String) async {
        let key = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard keyed[key] == nil, !needsSetup else { return }
        if let mine = assigned.first(where: { $0.key == key }) {
            keyed[key] = mine
            return
        }
        // A key that wasn't found, or a lookup that failed, isn't asked again
        // for a minute: the root search sends every keystroke.
        if let at = keyMisses[key], Date().timeIntervalSince(at) < 60 { return }
        do {
            if let issue = try await search(jql: "key = \"\(key)\"", limit: 1).first {
                if keyed.count >= 100 { keyed.removeAll() }
                keyed[key] = issue
                keyProblem = nil
            } else {
                keyMisses[key] = Date()
                keyProblem = nil
            }
        } catch {
            keyMisses[key] = Date()
            keyProblem = "Couldn't look up \(key): \(error)"
        }
        if keyMisses.count >= 100 { keyMisses = keyMisses.filter { Date().timeIntervalSince($0.value) < 60 } }
    }

    // MARK: Alerts

    static let urgentPriorities: Set<String> = ["Highest", "Blocker", "Critical"]

    /// Notifies about issues newly assigned to you since the last refresh,
    /// louder for Highest and Blocker. The first refresh only remembers.
    func noticeNewAssignments() {
        let keys = assigned.map(\.key)
        defer { seen = keys; seenReady = true }
        guard seenReady, notifyOnAssign else { return }
        let known = Set(seen)
        let fresh = assigned.filter { !known.contains($0.key) && $0.category != "done" }
        guard !fresh.isEmpty else { return }
        if fresh.count > 3 {
            Stackbar.notify("\(fresh.count) Jira issues assigned to you", body: fresh.prefix(3).map(\.key).joined(separator: ", ") + "…",
                            actions: [NotificationAction("Open Jira", url: "\(base)/jira/your-work")])
            return
        }
        for issue in fresh {
            let urgent = issue.fields.priority.map { Self.urgentPriorities.contains($0.name) } ?? false
            Stackbar.notify(urgent ? "\(issue.fields.priority?.name ?? "Urgent"): \(issue.key) assigned to you" : "\(issue.key) assigned to you",
                            body: issue.fields.summary, actions: [NotificationAction("Open", url: url(for: issue))])
        }
    }

    // MARK: Actions

    /// The signed-in user, as the assignee and watcher APIs want them.
    func myself() async throws -> String {
        if let me { return me }
        struct Me: Decodable { let accountId: String?; let name: String? }
        let reply = try JSONDecoder().decode(Me.self, from: try await api("/myself"))
        guard let id = isDataCenter ? reply.name : reply.accountId else { throw HostError("Jira didn't say who you are") }
        me = id
        return id
    }

    /// Whether `text` is a whole issue key (`ABC-123`) and not the start of one.
    static func isKey(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z][A-Za-z0-9_]*-\d+$"#, options: .regularExpression) != nil
    }

    /// The issue a typed key or a pasted issue link names, or nil for other text.
    static func key(in text: String) -> String? {
        if isKey(text) { return text.uppercased() }
        for pattern in [#"/browse/([A-Za-z][A-Za-z0-9_]*-\d+)"#, #"selectedIssue=([A-Za-z][A-Za-z0-9_]*-\d+)"#] {
            if let r = text.range(of: pattern, options: .regularExpression),
               let k = text[r].range(of: #"[A-Za-z][A-Za-z0-9_]*-\d+"#, options: .regularExpression) { return text[r][k].uppercased() }
        }
        return nil
    }

    func loadTransitions(_ key: String) async {
        struct Reply: Decodable { let transitions: [Transition] }
        // The view asks on every keystroke: partial keys always fail, and a
        // workflow already loaded stays until a move changes it, or a minute.
        guard Self.isKey(key) else { return }
        if transitions[key] != nil, let at = transitionsLoadedAt[key], Date().timeIntervalSince(at) < Self.transitionsTTL { return }
        do {
            transitions[key] = try JSONDecoder().decode(Reply.self, from: try await api("/issue/\(key)/transitions")).transitions
            transitionsLoadedAt[key] = Date()
            actionProblem = nil
        } catch {
            actionProblem = "\(error)"
        }
    }

    func move(_ key: String, with transition: Transition) async throws {
        do {
            _ = try await api("/issue/\(key)/transitions", method: "POST", body: ["transition": ["id": transition.id]])
            Stackbar.hud("\(key) moved to \(transition.to?.name ?? transition.name)")
            transitions[key] = nil
            transitionsLoadedAt[key] = nil
            try await refresh()
        } catch {
            Stackbar.hud("\(error)", isError: true)
        }
    }

    func assignToMe(_ key: String) async throws {
        do {
            let me = try await myself()
            _ = try await api("/issue/\(key)/assignee", method: "PUT", body: [isDataCenter ? "name" : "accountId": me])
            Stackbar.hud("\(key) assigned to you")
            try await refresh()
        } catch {
            Stackbar.hud("\(error)", isError: true)
        }
    }

    func watch(_ key: String) async throws {
        do {
            // The body is a bare JSON string: the account id or username.
            _ = try await api("/issue/\(key)/watchers", method: "POST", body: try await myself())
            Stackbar.hud("Watching \(key)")
        } catch {
            Stackbar.hud("\(error)", isError: true)
        }
    }

    func comment(_ key: String, _ text: String) async throws {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { actionProblem = "Write a comment first"; return }
        do {
            _ = try await api("/issue/\(key)/comment", method: "POST", body: ["body": isDataCenter ? body : Self.document(body)] as [String: Any])
            actionProblem = nil
            commentDone = "Comment added to \(key)"
            Stackbar.hud("Comment added to \(key)")
        } catch {
            actionProblem = "\(error)"
        }
    }

    // MARK: Rows

    func row(_ issue: Issue) -> Row {
        let subtitle = [issue.key, issue.fields.issuetype?.name, issue.fields.status?.name].compactMap { $0 }.joined(separator: " · ")
        var row = Row(issue.fields.summary, subtitle: subtitle, symbol: issue.category == "indeterminate" ? "circle.lefthalf.filled" : issue.category == "done" ? "checkmark.circle" : "circle", key: issue.id)
        if let priority = issue.fields.priority?.name, ["Highest", "High", "Blocker", "Critical"].contains(priority) {
            row = row.badge(priority, role: ["Highest", "Blocker"].contains(priority) ? .critical : .warning)
        }
        let link = url(for: issue)
        row = row
            .action("Open") { Stackbar.open(link) }
            .navigate("Change Status…", to: "status", arguments: ["key": issue.key], shortcut: "cmd+s")
            .navigate("Comment…", to: "comment", arguments: ["key": issue.key], shortcut: "cmd+k")
        if !assigned.contains(where: { $0.key == issue.key }) {
            row = row.action("Assign to Me", shortcut: "cmd+i") { try await self.assignToMe(issue.key) }
        }
        return row
            .action("Watch", shortcut: "cmd+shift+w") { try await self.watch(issue.key) }
            .action("Copy Link", shortcut: "cmd+c") { Stackbar.copy(link) }
            .action("Copy Key", shortcut: "cmd+shift+c") { Stackbar.copy(issue.key) }
            .action("Copy Branch Name", shortcut: "cmd+shift+b") { Stackbar.copy(Self.branchName(issue)) }
    }

    /// `ABC-123-fix-login-redirect`, which Jira's development panel links.
    static func branchName(_ issue: Issue) -> String {
        let words = issue.fields.summary.lowercased().split { !($0.isLetter || $0.isNumber) }.prefix(6)
        return ([issue.key] + words.map(String.init)).joined(separator: "-")
    }

    // MARK: Surfaces

    var inProgress: [Issue] { assigned.filter { $0.category == "indeterminate" } }

    /// Done issues from the panel JQL (when it includes them) and from the last week, once each.
    var done: [Issue] {
        var seen = Set<String>()
        return (assigned.filter { $0.category == "done" } + doneThisWeek).filter { seen.insert($0.id).inserted }
    }

    let theme = Theme.blue
    var needsSetup: Bool { isDataCenter ? false : Self.host(of: site) == nil || email.isEmpty }

    var menuBar: ViewContent {
        if problem != nil, loaded, !needsSetup {
            Label("", symbol: "square.stack.3d.up").role(.warning)
        } else if inProgress.isEmpty {
            Label("", symbol: "square.stack.3d.up").role(.secondary)
        } else {
            Label("\(inProgress.count)", symbol: "square.stack.3d.up.fill")
        }
    }

    /// In progress first, then the rest assigned; a click opens the issue.
    var widget: ViewContent {
        if needsSetup {
            EmptyState("Connect Jira", symbol: "link", message: "Set up your Jira account in Stackbar.", theme: theme)
        } else {
            PanelHeader(inProgress.isEmpty ? "\(assigned.count) assigned" : "\(inProgress.count) in progress", subtitle: "Jira", symbol: "square.stack.3d.up.fill", theme: theme)
            if assigned.isEmpty {
                EmptyState(problem == nil ? "Nothing assigned" : "Can't reach Jira", symbol: "checkmark.circle", theme: theme)
            } else {
                List(inProgress + assigned.filter { $0.category != "indeterminate" }) { issue in self.row(issue) }
            }
        }
    }

    var panel: ViewContent {
        VStack(spacing: Space.m) {
            if needsSetup {
                EmptyState("Connect Jira", symbol: "link", message: "Your Jira Cloud site and the email you sign in with. Then paste an API token from id.atlassian.com when Stackbar asks.", theme: theme)
                Card {
                    TextField("yourteam.atlassian.net", text: site, key: "site") { value in await self.setSite(value) }
                    TextField("you@example.com", text: email, key: "email") { value in await self.setEmail(value) }
                }
            } else if !loaded {
                PanelHeader("Jira", subtitle: "Checking…", symbol: "square.stack.3d.up.fill", theme: theme)
            } else if let problem, assigned.isEmpty {
                EmptyState("Can't reach Jira", symbol: "exclamationmark.triangle.fill", message: problem, theme: .critical) {
                    ActionButton("Try Again", symbol: "arrow.clockwise", theme: theme) { try await self.refresh() }
                }
            } else {
                let toDo = assigned.filter { $0.category == "new" }
                let done = self.done
                PanelHeader(inProgress.isEmpty ? (assigned.isEmpty ? "Nothing assigned" : "Nothing in progress") : "\(inProgress.count) in progress", subtitle: "\(toDo.count) to do · \(isDataCenter ? (URL(string: base)?.host ?? "Data Center") : Self.host(of: site) ?? site)", symbol: "square.stack.3d.up.fill", theme: theme)
                if !assigned.isEmpty {
                    HeroCard(theme: theme, look: .glow) {
                        HStack(spacing: Space.l) {
                            HeroStat("In progress", value: "\(inProgress.count)", theme: theme, live: !inProgress.isEmpty)
                            HeroStat("To do", value: "\(toDo.count)", theme: .neutral, symbol: "circle.dashed")
                            HeroStat("Done this week", value: "\(done.count)", theme: .success, symbol: "checkmark.circle.fill")
                            Spacer()
                        }
                        ProgressBar(value: Double(done.count), total: Double(max(1, assigned.filter { $0.category != "done" }.count + done.count))).foreground(theme.sweep)
                    }
                }
                if let problem { Banner(problem) }
                if assigned.isEmpty {
                    EmptyState("Nothing assigned to you", symbol: "checkmark", theme: .success)
                } else {
                    VStack(spacing: Space.s) {
                        if !inProgress.isEmpty {
                            Section("In progress · \(inProgress.count)") { ForEach(inProgress) { issue in self.row(issue) } }
                        }
                        if !toDo.isEmpty {
                            Section("To do · \(toDo.count)") { ForEach(toDo) { issue in self.row(issue) } }
                        }
                        if !done.isEmpty {
                            Section("Done · \(done.count)") { ForEach(done) { issue in self.row(issue) } }
                        }
                    }
                }
            }
        }
    }

    func setDeployment(_ value: String) async {
        guard value != deployment else { return }
        deployment = value
        projects = []
        me = nil
        server = nil
        seenReady = false
        try? await refresh()
    }

    func setSite(_ value: String) async {
        site = Self.host(of: value) ?? value
        projects = []
        me = nil
        seenReady = false
        try? await refresh()
    }

    func setEmail(_ value: String) async {
        email = value.trimmingCharacters(in: .whitespaces)
        me = nil
        seenReady = false
        try? await refresh()
    }

    var settings: ViewContent {
        Section("Account") {
            Picker("Jira", options: ["Cloud", "Data Center"], selection: deployment, style: .segmented) { value in await self.setDeployment(value) }
            if isDataCenter {
                LabeledContent("Server", value: server ?? "Not set: enter JIRA_SERVER_URL")
                Text("Enter your server's address (https://jira.example.com) as JIRA_SERVER_URL and a personal access token (your Jira profile > Personal Access Tokens) as JIRA_API_TOKEN. Stackbar keeps both in your Keychain and reaches that server and no other.").style(.caption)
            } else {
                LabeledContent("Site", value: Self.host(of: site) ?? "Not set")
                TextField("yourteam.atlassian.net", text: site, key: "site") { value in await self.setSite(value) }
                LabeledContent("Email", value: email.isEmpty ? "Not set" : email)
                TextField("you@example.com", text: email, key: "email") { value in await self.setEmail(value) }
                Text("Create an API token at id.atlassian.com > Security > API tokens. Stackbar asks for it the first time and keeps it in your Keychain as JIRA_API_TOKEN.").style(.caption)
            }
            if let problem { Text(problem).role(.warning).style(.caption) }
        }
        Section("Notifications") {
            Toggle("Notify when an issue is assigned to me", isOn: notifyOnAssign) { self.notifyOnAssign = $0 }
            Text("Highest and Blocker issues say so in the title.").style(.caption)
        }
        Section("Issues") {
            TextField("JQL for the panel", text: jql, key: "jql") { value in
                self.jql = value.trimmingCharacters(in: .whitespaces).isEmpty ? Self.defaultJQL : value
                self.seenReady = false
                try await self.refresh()
            }
            if jql != Self.defaultJQL {
                Button("Reset to Open Issues Assigned to Me", symbol: "arrow.uturn.backward") {
                    self.jql = Self.defaultJQL
                    self.seenReady = false
                    try await self.refresh()
                }
            }
            Text("Which issues the menu bar and panel show, as JQL.").style(.caption)
            if !projects.isEmpty {
                Picker("Default project for new issues", options: projects.map(\.name), selection: projects.first { $0.key == defaultProject }?.name ?? projects[0].name) { name in
                    self.defaultProject = self.projects.first { $0.name == name }?.key ?? ""
                }
            }
        }
    }

    // MARK: Commands

    var commands: [Command] {
        Command("my-issues", title: "My Jira Issues", symbol: "square.stack.3d.up", keywords: ["jira", "issue", "ticket", "assigned"])
            .view(search: { _ in try await self.refresh(maxAge: 30) }) { _ in
                if let problem = self.problem {
                    ContentUnavailableView("Can't reach Jira", symbol: "exclamationmark.triangle", message: problem)
                } else {
                    List(self.assigned, searchable: true) { issue in self.row(issue) }
                }
            }
        Command("search", title: "Search Jira", subtitle: "Text, a key like ABC-123, or a link", symbol: "magnifyingglass", keywords: ["jira", "issue", "find", "ticket"])
            .view(search: { invocation in await self.find(invocation.text) }) { invocation in
                if invocation.text.trimmingCharacters(in: .whitespaces).count < 2 {
                    ContentUnavailableView("Type to search, or paste a key", symbol: "magnifyingglass")
                } else if let problem = self.searchProblem {
                    ContentUnavailableView("Can't search Jira", symbol: "exclamationmark.triangle", message: problem)
                } else if self.found.isEmpty {
                    ContentUnavailableView("No issues match", symbol: "magnifyingglass")
                } else {
                    List(self.found) { issue in self.row(issue) }
                }
            }
        // An issue key typed at the palette's root opens that issue.
        Command("issue", title: "Jira Issue by Key", symbol: "square.stack.3d.up", keywords: ["jira"])
            .view(search: { invocation in await self.lookUp(key: invocation.text) }) { invocation in
                let issue = self.keyed[invocation.text.trimmingCharacters(in: .whitespaces).uppercased()]
                if issue == nil, let problem = self.keyProblem {
                    ContentUnavailableView("Can't look that up", symbol: "exclamationmark.triangle", message: problem)
                } else {
                    List(issue.map { [$0] } ?? []) { issue in self.row(issue) }
                }
            }
            .rootSearch(section: "Jira", matching: #"[A-Za-z][A-Za-z0-9_]*-\d+"#)
            .stackbarOnly()
        Command("status", title: "Change Jira Issue Status", symbol: "arrow.triangle.swap", keywords: ["jira", "transition", "move", "done", "progress"])
            .argument("key", placeholder: "ABC-123")
            .view(search: { invocation in
                if let key = invocation["key"]?.uppercased() { await self.loadTransitions(key) }
            }) { invocation in
                let key = invocation["key"]?.uppercased() ?? ""
                if key.isEmpty || !Self.isKey(key) {
                    ContentUnavailableView("Which issue?", symbol: "square.stack.3d.up", message: "Type its key, like ABC-123.")
                } else if let problem = self.actionProblem, self.transitions[key] == nil {
                    ContentUnavailableView("Can't load \(key)'s workflow", symbol: "exclamationmark.triangle", message: problem)
                } else {
                    List(self.transitions[key] ?? [], searchable: true) { transition in
                        let target = transition.to?.name ?? transition.name
                        let category = transition.to?.statusCategory?.key ?? "new"
                        Row(target, subtitle: transition.name == target ? key : "\(transition.name) · \(key)",
                            symbol: category == "done" ? "checkmark.circle" : category == "indeterminate" ? "circle.lefthalf.filled" : "circle", key: transition.id)
                            .action("Move to \(target)") { try await self.move(key, with: transition) }
                    }
                }
            }
            .stackbarOnly()
        Command("comment", title: "Comment on Jira Issue", symbol: "text.bubble", keywords: ["jira", "comment", "reply", "note"])
            .argument("key", placeholder: "ABC-123")
            .view { invocation in
                let key = invocation["key"]?.uppercased() ?? ""
                if key.isEmpty {
                    ContentUnavailableView("Which issue?", symbol: "square.stack.3d.up", message: "Type its key, like ABC-123.")
                } else {
                    Form(submit: "Add Comment", key: "comment-\(key)") {
                        FormField.multiline("Comment on \(key)", name: "body")
                    } onSubmit: { values in
                        try await self.comment(key, values.string("body") ?? "")
                    }
                    if let problem = self.actionProblem { Banner(problem) }
                    if let done = self.commentDone { Banner(done, symbol: "checkmark.circle.fill", theme: .success) }
                }
            }
            .stackbarOnly()
        Command("create", title: "Create Jira Issue", symbol: "plus.circle", keywords: ["jira", "issue", "new", "ticket", "bug"])
            .stackbarOnly()
            .view { _ in self.form }
    }

    @ViewBuilder var form: ViewContent {
        if projects.isEmpty {
            ContentUnavailableView("No projects yet", symbol: "square.stack.3d.up", message: problem ?? "Set up your Jira account in Settings, then try again.")
        } else {
            Form(submit: "Create Issue", key: "issue") {
                FormField.picker("Project", name: "project", options: projects.map(\.name), selection: projects.first { $0.key == defaultProject }?.name ?? projects[0].name)
                FormField.picker("Type", name: "type", options: ["Task", "Bug", "Story"], selection: "Task")
                FormField.text("Summary", name: "summary", error: formError)
                FormField.multiline("Description", name: "description")
            } onSubmit: { values in
                try await self.create(values)
            }
            if let created { Banner(created, symbol: "checkmark.circle.fill", theme: .success) }
        }
    }

    /// Plain paragraphs in Atlassian Document Format.
    static func document(_ text: String) -> [String: Any] {
        let paragraphs = text.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return ["type": "doc", "version": 1, "content": paragraphs.map { ["type": "paragraph", "content": [["type": "text", "text": $0]]] }]
    }

    func create(_ values: [String: EventValue]) async throws {
        let summary = (values.string("summary") ?? "").trimmingCharacters(in: .whitespaces)
        guard !summary.isEmpty else { formError = "Give it a summary"; return }
        guard let project = projects.first(where: { $0.name == values.string("project") }) ?? projects.first else { formError = "Pick a project"; return }
        formError = nil
        var fields: [String: Any] = ["project": ["key": project.key], "summary": summary, "issuetype": ["name": values.string("type") ?? "Task"]]
        if let description = values.string("description"), !description.isEmpty { fields["description"] = isDataCenter ? description : Self.document(description) }
        do {
            struct Created: Decodable { let key: String }
            let created = try JSONDecoder().decode(Created.self, from: try await api("/issue", method: "POST", body: ["fields": fields]))
            self.created = "Created \(created.key)"
            Stackbar.open(url(key: created.key))
            try await refresh()
        } catch {
            formError = "\(error)"
        }
    }

    var tools: [AgentTool] {
        AgentTool("assigned", description: "Open Jira issues assigned to the user, with key, status, type and summary") { _ in
            if !self.loaded { try await self.refresh() }
            if let problem = self.problem { return problem }
            return self.assigned.map { "\($0.key)\t\($0.fields.status?.name ?? "")\t\($0.fields.issuetype?.name ?? "")\t\($0.fields.summary)" }.joined(separator: "\n")
        }
    }
}
