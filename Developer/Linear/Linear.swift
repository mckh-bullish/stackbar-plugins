import StackbarKit
import Foundation

/// Your Linear issues in the menu bar and the palette: what's assigned to
/// you, grouped by state, with the branch name a keystroke away, and new
/// issues filed without leaving what you're doing.
///
/// It talks to Linear's GraphQL API with a personal API key (Settings >
/// Security & access > Personal API keys in Linear), kept in your Keychain
/// as `LINEAR_API_KEY`.
@main
final class Linear: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.linear",
        name: "Linear",
        version: "1.3.0",
        summary: "Your assigned Linear issues, branch names, search and new issues from the palette.",
        surfaces: [.menuBar, .panel, .settings],
        triggers: [.launch, .minutes(5), .wake],
        capabilities: [.network("api.linear.app"), .secret(name: "LINEAR_API_KEY")],
        minimumStackbar: "0.17.0",
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

    struct Issue: Codable, Equatable, Identifiable {
        struct State: Codable, Equatable { let name: String; let type: String }
        struct Team: Codable, Equatable { let key: String }
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
    @Stored("teams") var teams: [Team] = []
    @Stored("defaultTeam") var defaultTeam = ""
    @Stored("menuBarCount") var menuBarCount = "In progress"
    var problem: String?
    var loaded = false
    var formError: String?
    var created: String?

    static let fields = "id identifier title url branchName priority state { name type } team { key }"

    // MARK: API

    func query<T: Decodable>(_ text: String, variables: [String: Any] = [:], as type: T.Type = T.self) async throws -> T {
        guard let key = try await Stackbar.secret("LINEAR_API_KEY"), !key.isEmpty else {
            throw HostError("Add your Linear API key (LINEAR_API_KEY) to see your issues")
        }
        let body = try JSONSerialization.data(withJSONObject: ["query": text, "variables": variables])
        let response = try await Stackbar.http(HTTPRequest(url: "https://api.linear.app/graphql", method: "POST", headers: [
            "Authorization": key, "Content-Type": "application/json",
        ], body: body))
        guard response.status != 401 else { throw HostError("Linear rejected the API key (401); set a new LINEAR_API_KEY") }
        guard (200..<300).contains(response.status) || response.status == 400 else { throw HostError("Linear answered \(response.status)") }
        let reply = try JSONDecoder().decode(GraphQLReply<T>.self, from: response.body)
        if let data = reply.data { return data }
        throw HostError(reply.errors?.map(\.message).joined(separator: "; ") ?? "Linear sent no data")
    }

    func refresh() async throws {
        struct Data: Decodable {
            struct Viewer: Decodable { struct Issues: Decodable { let nodes: [Issue] }; let assignedIssues: Issues }
            struct Teams: Decodable { let nodes: [Team] }
            let viewer: Viewer
            let teams: Teams
        }
        do {
            let data = try await query("""
            query { viewer { assignedIssues(first: 100, orderBy: updatedAt, filter: { state: { type: { nin: ["completed", "canceled"] } } }) { nodes { \(Self.fields) } } } \
            teams(first: 50) { nodes { id key name } } }
            """, as: Data.self)
            assigned = data.viewer.assignedIssues.nodes
            teams = data.teams.nodes
            problem = nil
        } catch {
            problem = "\(error)"
        }
        loaded = true
    }

    func search(_ text: String) async {
        let term = text.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2 else { found = []; return }
        struct Data: Decodable { struct Issues: Decodable { let nodes: [Issue] }; let issues: Issues }
        do {
            let data = try await query("query($term: String!) { issues(first: 25, orderBy: updatedAt, filter: { title: { containsIgnoreCase: $term } }) { nodes { \(Self.fields) } } }", variables: ["term": term], as: Data.self)
            found = data.issues.nodes
        } catch {
            found = []
        }
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

    var menuBar: ViewContent {
        let count = menuBarCount == "All assigned" ? assigned.count : inProgress.count
        if problem != nil, loaded {
            Label("", symbol: "checklist").role(.warning)
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
                if problem.contains("LINEAR_API_KEY") && !problem.contains("401") {
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
            .view(search: { _ in try await self.refresh() }) { _ in
                if let problem = self.problem {
                    ContentUnavailableView("Can't reach Linear", symbol: "exclamationmark.triangle", message: problem)
                } else {
                    List(self.assigned, searchable: true) { issue in self.row(issue) }
                }
            }
        Command("search", title: "Search Linear Issues", symbol: "magnifyingglass", keywords: ["linear", "issue", "find"])
            .view(search: { invocation in await self.search(invocation.text) }) { invocation in
                if invocation.text.count < 2 {
                    ContentUnavailableView("Type to search issue titles", symbol: "magnifyingglass")
                } else {
                    List(self.found) { issue in self.row(issue) }
                }
            }
        Command("create", title: "Create Linear Issue", symbol: "plus.circle", keywords: ["linear", "issue", "new", "ticket"])
            .stackbarOnly()
            .view { _ in self.form }
    }

    @ViewBuilder var form: ViewContent {
        if teams.isEmpty {
            ContentUnavailableView("No teams yet", symbol: "person.3", message: problem ?? "Add your Linear API key, then try again.")
        } else {
            Form(submit: "Create Issue", key: "issue") {
                FormField.picker("Team", name: "team", options: teams.map(\.name), selection: teams.first { $0.id == defaultTeam }?.name ?? teams[0].name)
                FormField.text("Title", name: "title", error: formError)
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

    var tools: [AgentTool] {
        AgentTool("assigned", description: "Open Linear issues assigned to the user, with identifier, state, priority, title and branch name") { _ in
            if !self.loaded { try await self.refresh() }
            if let problem = self.problem { return problem }
            return self.assigned.map { "\($0.identifier)\t\($0.state.name)\t\(Self.priorityName($0.priority) ?? "-")\t\($0.title)\t\($0.branchName)" }.joined(separator: "\n")
        }
    }
}
