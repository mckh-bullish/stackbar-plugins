import StackbarKit
import Foundation

/// Your Jira Cloud issues in the menu bar and the palette: what's assigned
/// to you, search by text or key, and new issues without opening Jira.
///
/// It signs in to your site (`yourteam.atlassian.net`) with your email and
/// an API token from id.atlassian.com, kept in your Keychain as
/// `JIRA_API_TOKEN`. Requests go only to `*.atlassian.net`.
@main
final class Jira: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.jira",
        name: "Jira",
        version: "1.4.0",
        summary: "Your assigned Jira Cloud issues, search and new issues from the palette.",
        surfaces: [.menuBar, .panel, .widget, .settings],
        triggers: [.launch, .minutes(5), .wake],
        capabilities: [.network("*.atlassian.net"), .secret(name: "JIRA_API_TOKEN")],
        minimumStackbar: "0.21.0",
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
    var assigned: [Issue] = []
    /// The issue an issue key typed at the palette's root names.
    var keyed: [String: Issue] = [:]
    var found: [Issue] = []
    /// Why the last search failed, shown instead of an empty list.
    var searchProblem: String?
    /// Your issues that moved to Done in the last week. The panel JQL leaves
    /// Done out by default, so this is a query of its own.
    var doneThisWeek: [Issue] = []
    var problem: String?
    var loaded = false
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

    func url(for issue: Issue) -> String {
        "https://\(Self.host(of: site) ?? "")/browse/\(issue.key)"
    }

    // MARK: API

    func api(_ path: String, method: String = "GET", body: Any? = nil) async throws -> Data {
        guard let host = Self.host(of: site), !email.isEmpty else {
            throw HostError("Set your Jira site and email in Settings")
        }
        guard let token = try await Stackbar.secret("JIRA_API_TOKEN"), !token.isEmpty else {
            throw HostError("Add your Jira API token (JIRA_API_TOKEN) from id.atlassian.com")
        }
        let basic = Data("\(email):\(token)".utf8).base64EncodedString()
        let response = try await Stackbar.http(HTTPRequest(url: "https://\(host)\(path)", method: method, headers: [
            "Authorization": "Basic \(basic)", "Accept": "application/json", "Content-Type": "application/json",
        ], body: try body.map { try JSONSerialization.data(withJSONObject: $0) }))
        switch response.status {
        case 200..<300: return response.body
        case 401: throw HostError("Jira rejected the email or API token (401)")
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
        let data = try await api("/rest/api/3/search/jql", method: "POST", body: ["jql": jql, "fields": Self.fields, "maxResults": limit] as [String: Any])
        return try JSONDecoder().decode(Reply.self, from: data).issues
    }

    func refresh() async throws {
        guard Self.host(of: site) != nil, !email.isEmpty else {
            problem = "Set your Jira site and email in Settings"
            loaded = true
            return
        }
        do {
            assigned = try await search(jql: jql)
            // Only a stat, so a site that rejects this query keeps the rest of the panel.
            doneThisWeek = (try? await search(jql: Self.doneJQL, limit: 50)) ?? []
            if projects.isEmpty { try await loadProjects() }
            problem = nil
        } catch {
            problem = "\(error)"
        }
        loaded = true
    }

    func loadProjects() async throws {
        struct Reply: Decodable { let values: [Project] }
        let data = try await api("/rest/api/3/project/search?maxResults=50&orderBy=-lastIssueUpdatedTime")
        projects = try JSONDecoder().decode(Reply.self, from: data).values
    }

    /// A key like `ABC-123` is looked up directly; anything else is a text search.
    func find(_ text: String) async {
        let term = text.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2 else { found = []; searchProblem = nil; return }
        let escaped = term.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let isKey = term.range(of: #"^[A-Za-z][A-Za-z0-9_]+-\d+$"#, options: .regularExpression) != nil
        let query = isKey ? "key = \"\(escaped.uppercased())\"" : "text ~ \"\(escaped)\" ORDER BY updated DESC"
        do {
            found = try await search(jql: query, limit: 25)
            searchProblem = nil
        } catch {
            found = []
            searchProblem = "\(error)"
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
        if let issue = try? await search(jql: "key = \"\(key)\"", limit: 1).first { keyed[key] = issue }
    }

    // MARK: Rows

    func row(_ issue: Issue) -> Row {
        let subtitle = [issue.key, issue.fields.issuetype?.name, issue.fields.status?.name].compactMap { $0 }.joined(separator: " · ")
        var row = Row(issue.fields.summary, subtitle: subtitle, symbol: issue.category == "indeterminate" ? "circle.lefthalf.filled" : issue.category == "done" ? "checkmark.circle" : "circle", key: issue.id)
        if let priority = issue.fields.priority?.name, ["Highest", "High", "Blocker", "Critical"].contains(priority) {
            row = row.badge(priority, role: ["Highest", "Blocker"].contains(priority) ? .critical : .warning)
        }
        let link = url(for: issue)
        return row
            .action("Open") { Stackbar.open(link) }
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
    var needsSetup: Bool { Self.host(of: site) == nil || email.isEmpty }

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
                PanelHeader(inProgress.isEmpty ? (assigned.isEmpty ? "Nothing assigned" : "Nothing in progress") : "\(inProgress.count) in progress", subtitle: "\(toDo.count) to do · \(Self.host(of: site) ?? site)", symbol: "square.stack.3d.up.fill", theme: theme)
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

    func setSite(_ value: String) async {
        site = Self.host(of: value) ?? value
        projects = []
        try? await refresh()
    }

    func setEmail(_ value: String) async {
        email = value.trimmingCharacters(in: .whitespaces)
        try? await refresh()
    }

    var settings: ViewContent {
        Section("Account") {
            LabeledContent("Site", value: Self.host(of: site) ?? "Not set")
            TextField("yourteam.atlassian.net", text: site, key: "site") { value in await self.setSite(value) }
            LabeledContent("Email", value: email.isEmpty ? "Not set" : email)
            TextField("you@example.com", text: email, key: "email") { value in await self.setEmail(value) }
            Text("Create an API token at id.atlassian.com > Security > API tokens. Stackbar asks for it the first time and keeps it in your Keychain as JIRA_API_TOKEN.").style(.caption)
            if let problem { Text(problem).role(.warning).style(.caption) }
        }
        Section("Issues") {
            TextField("JQL for the panel", text: jql, key: "jql") { value in
                self.jql = value.trimmingCharacters(in: .whitespaces).isEmpty ? Self.defaultJQL : value
                try await self.refresh()
            }
            if jql != Self.defaultJQL {
                Button("Reset to Open Issues Assigned to Me", symbol: "arrow.uturn.backward") {
                    self.jql = Self.defaultJQL
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
            .view(search: { _ in try await self.refresh() }) { _ in
                if let problem = self.problem {
                    ContentUnavailableView("Can't reach Jira", symbol: "exclamationmark.triangle", message: problem)
                } else {
                    List(self.assigned, searchable: true) { issue in self.row(issue) }
                }
            }
        Command("search", title: "Search Jira", subtitle: "Text, or a key like ABC-123", symbol: "magnifyingglass", keywords: ["jira", "issue", "find", "ticket"])
            .view(search: { invocation in await self.find(invocation.text) }) { invocation in
                if invocation.text.count < 2 {
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
                List(self.keyed[invocation.text.trimmingCharacters(in: .whitespaces).uppercased()].map { [$0] } ?? []) { issue in self.row(issue) }
            }
            .rootSearch(section: "Jira", matching: #"[A-Za-z][A-Za-z0-9_]*-\d+"#)
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
        if let description = values.string("description"), !description.isEmpty { fields["description"] = Self.document(description) }
        do {
            struct Created: Decodable { let key: String }
            let created = try JSONDecoder().decode(Created.self, from: try await api("/rest/api/3/issue", method: "POST", body: ["fields": fields]))
            self.created = "Created \(created.key)"
            Stackbar.open("https://\(Self.host(of: site) ?? "")/browse/\(created.key)")
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
