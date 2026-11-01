import StackbarKit
import Foundation

/// GitHub from the palette: jump to any of your repositories (or its issues,
/// pull requests and Actions), see the issues assigned to you, and file a
/// new issue without opening a browser first.
///
/// It uses the same `GITHUB_TOKEN` as PR Cockpit, so one token serves both.
/// A fine-grained token with read access to metadata and issues covers
/// everything except creating issues, which needs write access to issues.
@main
final class GitHub: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.github",
        name: "GitHub",
        version: "1.0.0",
        summary: "Your repositories and issues from the palette, and new issues without a browser.",
        surfaces: [.panel, .settings],
        triggers: [.launch, .minutes(30), .wake],
        capabilities: [.network("api.github.com"), .secret(name: "GITHUB_TOKEN")],
        minimumStackbar: "0.11.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Developer/GitHub"
    )

    struct Repo: Codable, Equatable, Identifiable {
        let id: Int
        let full_name: String
        let html_url: String
        let ssh_url: String
        let clone_url: String
        let description: String?
        let `private`: Bool
        let fork: Bool
        let archived: Bool
        let has_issues: Bool
        let open_issues_count: Int
        let stargazers_count: Int
        let pushed_at: Date?
    }

    struct Issue: Decodable, Equatable, Identifiable {
        struct Label: Decodable, Equatable { let name: String }
        struct Repository: Decodable, Equatable { let full_name: String }
        let id: Int
        let number: Int
        let title: String
        let html_url: String
        let updated_at: Date
        let labels: [Label]
        let repository: Repository?
        let pull_request: [String: String?]?
    }

    @Stored("repos") var repos: [Repo] = []
    @Stored("recent") var recent: [String] = []
    @Stored("includeArchived") var includeArchived = false
    @Stored("cloneWith") var cloneWith = "SSH"
    var issues: [Issue] = []
    var searchResults: [Repo] = []
    var problem: String?
    var formError: String?
    var created: String?

    // MARK: API

    func token() async throws -> String {
        guard let token = try await Stackbar.secret("GITHUB_TOKEN"), !token.isEmpty else {
            throw HostError("Add a GitHub token (GITHUB_TOKEN) to use GitHub")
        }
        return token
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func api(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        let response = try await Stackbar.http(HTTPRequest(url: "https://api.github.com" + path, method: method, headers: [
            "Authorization": "Bearer \(try await token())",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "Content-Type": "application/json",
        ], body: body))
        switch response.status {
        case 200..<300: return response.body
        case 401: throw HostError("GitHub rejected the token (401); set a new GITHUB_TOKEN")
        case 403, 404:
            struct Message: Decodable { let message: String }
            let message = (try? JSONDecoder().decode(Message.self, from: response.body))?.message ?? "not allowed"
            throw HostError("GitHub said \(response.status): \(message). The token may need more access.")
        case 422: throw HostError("GitHub couldn't do that (422): \(String(decoding: response.body.prefix(200), as: UTF8.self))")
        default: throw HostError("GitHub answered \(response.status)")
        }
    }

    func refresh() async throws {
        do {
            try await loadRepos()
            try await loadIssues()
            problem = nil
        } catch {
            problem = "\(error)"
        }
    }

    /// Your repositories and those of your organizations, most recently
    /// pushed first; three pages of 100 at most.
    func loadRepos() async throws {
        var all: [Repo] = []
        for page in 1...3 {
            let data = try await api("/user/repos?sort=pushed&per_page=100&page=\(page)&affiliation=owner,collaborator,organization_member")
            let batch = try Self.decoder.decode([Repo].self, from: data)
            all += batch
            if batch.count < 100 { break }
        }
        repos = all
    }

    func loadIssues() async throws {
        let data = try await api("/issues?filter=assigned&state=open&per_page=50&sort=updated")
        issues = try Self.decoder.decode([Issue].self, from: data).filter { $0.pull_request == nil }
    }

    func search(_ text: String) async {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard query.count >= 3, matching(query).count < 5 else {
            searchResults = []
            return
        }
        struct Reply: Decodable { let items: [Repo] }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
        do {
            let data = try await api("/search/repositories?q=\(encoded)&per_page=10")
            searchResults = try Self.decoder.decode(Reply.self, from: data).items
        } catch {
            searchResults = []
        }
    }

    func matching(_ text: String) -> [Repo] {
        let words = text.lowercased().split(separator: " ")
        return shownRepos.filter { repo in words.allSatisfy { repo.full_name.lowercased().contains($0) } }
    }

    var shownRepos: [Repo] {
        repos.filter { includeArchived || !$0.archived }
    }

    /// Recently opened first, then most recently pushed.
    var ordered: [Repo] {
        let rank = Dictionary(recent.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return shownRepos.sorted { (rank[$0.full_name] ?? Int.max, $0.pushed_at.map { -$0.timeIntervalSince1970 } ?? 0) < (rank[$1.full_name] ?? Int.max, $1.pushed_at.map { -$0.timeIntervalSince1970 } ?? 0) }
    }

    func opened(_ repo: Repo) {
        recent = Array(([repo.full_name] + recent.filter { $0 != repo.full_name }).prefix(10))
    }

    // MARK: Rows

    func row(_ repo: Repo) -> Row {
        var row = Row(repo.full_name, subtitle: repo.description, symbol: repo.private ? "lock" : "book.closed", key: "repo-\(repo.id)")
        if repo.archived { row = row.badge("archived") }
        if repo.fork { row = row.badge("fork") }
        return row
            .action("Open") { self.opened(repo); Stackbar.open(repo.html_url) }
            .action("Issues", shortcut: "cmd+i") { self.opened(repo); Stackbar.open(repo.html_url + "/issues") }
            .action("Pull Requests", shortcut: "cmd+p") { self.opened(repo); Stackbar.open(repo.html_url + "/pulls") }
            .action("Actions", shortcut: "cmd+shift+a") { self.opened(repo); Stackbar.open(repo.html_url + "/actions") }
            .action("Copy Clone URL", shortcut: "cmd+shift+c") { Stackbar.copy(self.cloneWith == "HTTPS" ? repo.clone_url : repo.ssh_url) }
            .action("Copy URL", shortcut: "cmd+c") { Stackbar.copy(repo.html_url) }
            .navigate("New Issue", to: "create-issue", arguments: ["repo": repo.full_name], shortcut: "cmd+n")
    }

    func row(_ issue: Issue) -> Row {
        var row = Row(issue.title, subtitle: "\(issue.repository?.full_name ?? "")#\(issue.number)", symbol: "smallcircle.filled.circle", key: "issue-\(issue.id)")
        for label in issue.labels.prefix(2) { row = row.badge(label.name) }
        return row
            .action("Open") { Stackbar.open(issue.html_url) }
            .action("Copy Link", shortcut: "cmd+c") { Stackbar.copy(issue.html_url) }
            .action("Copy Reference", shortcut: "cmd+shift+c") { Stackbar.copy("\(issue.repository?.full_name ?? "")#\(issue.number)") }
    }

    // MARK: Commands

    var commands: [Command] {
        Command("repos", title: "Search GitHub Repositories", symbol: "book.closed", keywords: ["github", "repo", "repository", "gh"])
            .view(search: { invocation in
                if self.repos.isEmpty { try await self.refresh() }
                await self.search(invocation.text)
            }) { _ in
                if let problem = self.problem, self.repos.isEmpty {
                    ContentUnavailableView("Can't reach GitHub", symbol: "exclamationmark.triangle", message: problem)
                } else {
                    List(searchable: true) {
                        ForEach(self.ordered) { repo in self.row(repo) }
                        ForEach(self.searchResults.filter { result in !self.repos.contains { $0.id == result.id } }) { repo in self.row(repo) }
                    }
                }
            }
        Command("issues", title: "My GitHub Issues", subtitle: "Open issues assigned to you", symbol: "smallcircle.filled.circle", keywords: ["github", "issue", "assigned", "gh"])
            .view(search: { _ in
                do { try await self.loadIssues(); self.problem = nil } catch { self.problem = "\(error)" }
            }) { _ in
                if let problem = self.problem {
                    ContentUnavailableView("Can't reach GitHub", symbol: "exclamationmark.triangle", message: problem)
                } else if self.issues.isEmpty {
                    ContentUnavailableView("Nothing assigned to you", symbol: "checkmark.circle")
                } else {
                    List(self.issues, searchable: true) { issue in self.row(issue) }
                }
            }
        Command("create-issue", title: "Create GitHub Issue", symbol: "plus.circle", keywords: ["github", "issue", "new", "bug", "gh"])
            .argument("repo", placeholder: "Repository", required: false)
            .stackbarOnly()
            .view { invocation in self.issueForm(repo: invocation["repo"]) }
    }

    @ViewBuilder func issueForm(repo: String?) -> ViewContent {
        let names = shownRepos.filter(\.has_issues).map(\.full_name)
        if names.isEmpty {
            ContentUnavailableView("No repositories yet", symbol: "book.closed", message: problem ?? "Add a GitHub token, then try again.")
        } else {
            Form(submit: "Create Issue", key: "issue") {
                FormField.picker("Repository", name: "repo", options: names, selection: repo.flatMap { names.contains($0) ? $0 : nil } ?? recent.first { names.contains($0) } ?? names.first)
                FormField.text("Title", name: "title", error: formError)
                FormField.multiline("Description", name: "body", placeholder: "Markdown")
            } onSubmit: { values in
                try await self.createIssue(values)
            }
            if let created { Text(created).style(.caption) }
        }
    }

    func createIssue(_ values: [String: EventValue]) async throws {
        let title = (values.string("title") ?? "").trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { formError = "Give it a title"; return }
        guard let repo = values.string("repo"), repo.split(separator: "/").count == 2 else { formError = "Pick a repository"; return }
        formError = nil
        let body = try JSONSerialization.data(withJSONObject: ["title": title, "body": values.string("body") ?? ""])
        do {
            let data = try await api("/repos/\(repo)/issues", method: "POST", body: body)
            struct Created: Decodable { let html_url: String; let number: Int }
            let issue = try Self.decoder.decode(Created.self, from: data)
            created = "Created \(repo)#\(issue.number)"
            Stackbar.open(issue.html_url)
        } catch {
            formError = "\(error)"
        }
    }

    // MARK: Panel and settings

    var panel: ViewContent {
        if let problem, repos.isEmpty {
            ContentUnavailableView("Can't reach GitHub", symbol: "exclamationmark.triangle", message: problem)
        } else {
            if !issues.isEmpty {
                Section("Assigned to you") {
                    ForEach(issues.prefix(5)) { issue in self.row(issue) }
                }
            }
            Section("Repositories") {
                ForEach(ordered.prefix(8)) { repo in self.row(repo) }
            }
            Text("Search all \(shownRepos.count) with Search GitHub Repositories in the palette.").style(.caption)
        }
    }

    var settings: ViewContent {
        Section("Repositories") {
            LabeledContent("Loaded", value: "\(repos.count)")
            Toggle("Include archived", isOn: includeArchived) { self.includeArchived = $0 }
            Picker("Copy clone URLs as", options: ["SSH", "HTTPS"], selection: cloneWith) { self.cloneWith = $0 }
            Button("Reload", symbol: "arrow.clockwise") { try await self.refresh() }
        }
        Section("Token") {
            Text("Uses GITHUB_TOKEN, shared with PR Cockpit. A fine-grained token with read access to metadata and issues works; creating issues needs write access to issues.").style(.caption)
            if let problem { Text(problem).role(.warning).style(.caption) }
        }
    }
}
