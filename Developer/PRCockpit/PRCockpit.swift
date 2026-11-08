import StackbarKit
import Foundation

/// Your pull requests and the ones waiting on your review, with CI and review
/// state, in the menu bar; the issues assigned to you; and your repositories
/// and new issues from the palette. (The separate GitHub plugin is now part
/// of this one.)
///
/// One GraphQL request a refresh fetches both lists with their checks, review
/// decision and merge conflicts, alongside (not after) the issues and inbox
/// requests, so a refresh is as slow as the slowest of them. Clicks wait for a
/// running refresh, so keeping it short keeps switching tabs quick. A setting
/// limits the lists to what changed in the last few days. It tells you when
/// someone asks for your review, and when one of your own PRs is approved, gets changes requested,
/// or its checks fail. The token is a `GITHUB_TOKEN` secret the host keeps in
/// the Keychain (a fine-grained token with read access to pull requests,
/// issues and metadata covers everything but creating issues, which needs
/// write access to issues), and every request goes through the host to the
/// one declared domain. For GitHub Enterprise Server, turn it on in Settings
/// and enter the server as `GITHUB_ENTERPRISE_URL`: requests then go to that
/// server and no other.
@main
final class PRCockpit: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.pr-cockpit",
        name: "PR Cockpit",
        version: "1.11.0",
        summary: "Your pull requests, reviews and issues with CI and review state, and your repositories a keystroke away.",
        surfaces: [.menuBar, .panel, .window, .widget, .settings],
        triggers: [.launch, .every(.seconds(20)), .wake],
        capabilities: [.network("api.github.com"), .secret(name: "GITHUB_TOKEN"), .userServer(secret: "GITHUB_ENTERPRISE_URL")],
        minimumStackbar: "0.31.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Developer/PRCockpit",
        accent: .violet,
        symbol: "arrow.triangle.pull"
    )

    // MARK: Previews

    static let previews: [PreviewScene<PRCockpit>] = [
        PreviewScene("hero", "Every pull request waiting on you") { plugin in sample(plugin) },
        PreviewScene("mine", "Your own PRs: checks, reviews and conflicts") { plugin in
            sample(plugin)
            plugin.tab = Tab.mine.rawValue
        },
        PreviewScene("checks", "Why a check failed, and its preview deploy, without leaving the menu bar") { plugin in
            sample(plugin)
            plugin.tab = Tab.mine.rawValue
            let url = "https://github.com/acme/web/pull/1485"
            let now = Date()
            func check(_ name: String, _ state: CheckItem.State, required: Bool = false, step: String? = nil, notes: [String] = [], minutes: Double) -> CheckItem {
                CheckItem(id: name, name: name, group: "CI", state: state, isRequired: required, url: url + "/checks", startedAt: now.addingTimeInterval(-minutes * 60 - 200),
                          completedAt: state == .running ? nil : now.addingTimeInterval(-minutes * 60), failedStep: step, annotations: notes, runID: 4242, note: nil)
            }
            plugin.details[url] = PRDetails(checks: [
                check("test (macos-26)", .failed, required: true, step: "Run swift test", notes: ["Tests/OrderTests.swift:88 XCTAssertEqual failed: (\"dark\") is not equal to (\"light\")"], minutes: 3),
                check("lint", .running, minutes: 0),
                check("build (ubuntu)", .passed, required: true, minutes: 6),
                check("typecheck", .passed, minutes: 7),
            ], deployments: [
                DeployItem(id: "d1", environment: "Preview", state: "SUCCESS", url: "https://web-git-dark-mode-acme.vercel.app", logURL: nil, createdAt: now.addingTimeInterval(-240)),
            ], fetchedAt: now)
            plugin.expanded = url
            plugin.expandedAt = now
        },
        PreviewScene("dashboard", "Both lists, what merged and how long reviews wait", surface: .window) { plugin in sample(plugin) },
        PreviewScene("widget", "Your review queue on the desktop", surface: .widget) { plugin in sample(plugin) },
    ]

    static func sample(_ plugin: PRCockpit) {
        let now = Date()
        func pr(_ repo: String, _ number: Int, _ title: String, by author: String, minutesAgo: Double, review: String?, checks: String?,
                mergeable: String = "MERGEABLE", draft: Bool = false, plus: Int, minus: Int, comments: Int) -> PullRequest {
            PullRequest(number: number, title: title, url: "https://github.com/\(repo)/pull/\(number)", isDraft: draft,
                        updatedAt: now.addingTimeInterval(-minutesAgo * 60), repository: .init(nameWithOwner: repo), author: .init(login: author),
                        reviewDecision: review, mergeable: mergeable, headRefName: "feature/\(number)", additions: plus, deletions: minus,
                        commits: checks.map { .init(nodes: [.init(commit: .init(statusCheckRollup: .init(state: $0)))]) },
                        comments: .init(totalCount: comments), state: "OPEN")
        }
        plugin.toReview = [
            pr("acme/web", 1482, "Add Apple Pay to checkout", by: "priya-dev", minutesAgo: 8, review: "REVIEW_REQUIRED", checks: "SUCCESS", plus: 412, minus: 38, comments: 3),
            pr("acme/api", 977, "Rate-limit the export endpoint", by: "marco-k", minutesAgo: 35, review: "REVIEW_REQUIRED", checks: "PENDING", plus: 96, minus: 12, comments: 1),
            pr("acme/web", 1479, "Fix layout shift on product pages", by: "lena-w", minutesAgo: 120, review: "CHANGES_REQUESTED", checks: "SUCCESS", plus: 28, minus: 41, comments: 6),
            pr("acme/ios", 311, "Push notification when an order ships", by: "tom-b", minutesAgo: 260, review: "REVIEW_REQUIRED", checks: "FAILURE", plus: 233, minus: 17, comments: 0),
        ]
        plugin.mine = [
            pr("acme/api", 981, "Move cron jobs to the queue", by: "you", minutesAgo: 15, review: "APPROVED", checks: "SUCCESS", plus: 188, minus: 140, comments: 4),
            pr("acme/web", 1485, "Dark mode for the order screen", by: "you", minutesAgo: 50, review: "REVIEW_REQUIRED", checks: "PENDING", plus: 77, minus: 9, comments: 0),
            pr("acme/api", 969, "Audit log for admin actions", by: "you", minutesAgo: 1440, review: "REVIEW_REQUIRED", checks: "SUCCESS", mergeable: "CONFLICTING", plus: 520, minus: 61, comments: 2),
        ]
        plugin.recentlyClosed = [
            pr("acme/web", 1474, "Remove the legacy cart endpoint", by: "you", minutesAgo: 300, review: "APPROVED", checks: "SUCCESS", plus: 12, minus: 340, comments: 2),
        ].map { PullRequest(number: $0.number, title: $0.title, url: $0.url, isDraft: false, updatedAt: $0.updatedAt, repository: $0.repository, author: $0.author,
                            reviewDecision: $0.reviewDecision, mergeable: nil, headRefName: $0.headRefName, additions: $0.additions, deletions: $0.deletions,
                            commits: $0.commits, comments: $0.comments, state: "MERGED") }
        plugin.history = [3, 4, 2, 5, 6, 4, 3, 5, 7, 4]
        plugin.updatedAt = now
        plugin.loaded = true
    }

    struct PullRequest: Decodable, Equatable {
        let number: Int
        let title: String
        let url: String
        let isDraft: Bool
        let updatedAt: Date
        let repository: Repository
        let author: Author?
        let reviewDecision: String?
        let mergeable: String?
        let headRefName: String?
        let additions: Int?
        let deletions: Int?
        let commits: Commits?
        let comments: Count?
        /// OPEN, CLOSED or MERGED.
        let state: String?

        struct Count: Decodable, Equatable { let totalCount: Int }

        struct Repository: Decodable, Equatable { let nameWithOwner: String }
        struct Author: Decodable, Equatable { let login: String }
        struct Commits: Decodable, Equatable {
            struct Node: Decodable, Equatable {
                struct Commit: Decodable, Equatable {
                    struct Rollup: Decodable, Equatable { let state: String }
                    let statusCheckRollup: Rollup?
                }
                let commit: Commit
            }
            let nodes: [Node]
        }

        var repo: String { repository.nameWithOwner }
        var id: String { "\(repo)#\(number)" }

        /// SUCCESS, FAILURE, ERROR, PENDING, EXPECTED, or nil without checks.
        var checks: String? { commits?.nodes.last?.commit.statusCheckRollup?.state }
        var checksFailed: Bool { checks == "FAILURE" || checks == "ERROR" }
        /// Approved (or needing no review), checks green, no conflicts.
        var readyToMerge: Bool {
            !isDraft && (reviewDecision == "APPROVED" || reviewDecision == nil) && checks == "SUCCESS" && mergeable == "MERGEABLE"
        }
    }

    enum Tab: String, CaseIterable {
        case review = "To review"
        case mine = "Mine"
        case issues = "Issues"
        case inbox = "Inbox"

        /// Short, so four tabs and their counts fit the panel's width.
        var title: String { self == .review ? "Review" : rawValue }
    }

    /// One of your repositories (REST).
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

    /// An issue assigned to you (REST).
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

        var reference: String { "\(repository?.full_name ?? "")#\(number)" }
    }

    /// One thread from GitHub's notifications inbox (REST).
    struct InboxItem: Decodable, Equatable {
        struct Subject: Decodable, Equatable {
            let title: String
            let url: String?
            let type: String
        }
        struct Repository: Decodable, Equatable {
            let full_name: String
            let html_url: String
        }
        let id: String
        let reason: String
        let unread: Bool
        let updated_at: Date
        let subject: Subject
        let repository: Repository

        /// The page on github.com (or the Enterprise server): the API URL
        /// turned into the web one.
        var webURL: String {
            guard let api = subject.url, let repos = api.range(of: "/repos/") else {
                return subject.type == "Release" ? repository.html_url + "/releases" : repository.html_url
            }
            // html_url is https://host/owner/repo; the web root is what comes before owner/repo.
            let webRoot = repository.html_url.hasSuffix(repository.full_name)
                ? String(repository.html_url.dropLast(repository.full_name.count)) : "https://github.com/"
            return webRoot + api[repos.upperBound...]
                .replacingOccurrences(of: "/pulls/", with: "/pull/")
                .replacingOccurrences(of: "/commits/", with: "/commit/")
        }

        var reasonText: String {
            switch reason {
            case "mention": return "mentioned you"
            case "team_mention": return "mentioned your team"
            case "review_requested": return "review requested"
            case "assign": return "assigned to you"
            case "author": return "you opened it"
            case "comment": return "new comment"
            case "ci_activity": return "CI activity"
            case "state_change": return "state changed"
            case "subscribed", "manual": return "watching"
            default: return reason.replacingOccurrences(of: "_", with: " ")
            }
        }

        var symbol: String {
            switch subject.type {
            case "PullRequest": return "arrow.triangle.pull"
            case "Issue": return "smallcircle.filled.circle"
            case "Release": return "tag"
            case "Discussion": return "bubble.left.and.bubble.right"
            case "CheckSuite": return "checkmark.seal"
            default: return "bell"
            }
        }
    }

    private struct Reply: Decodable {
        struct Data: Decodable {
            /// Search results, skipping any node that isn't a pull request.
            struct Search: Decodable {
                let nodes: [PullRequest]
                /// How many pull requests match, however many were sent.
                let issueCount: Int?
                private enum Keys: String, CodingKey { case nodes, issueCount }
                private struct Skip: Decodable {}

                init(from decoder: Decoder) throws {
                    let keys = try decoder.container(keyedBy: Keys.self)
                    issueCount = try keys.decodeIfPresent(Int.self, forKey: .issueCount)
                    var list = try keys.nestedUnkeyedContainer(forKey: .nodes)
                    var found: [PullRequest] = []
                    while !list.isAtEnd {
                        if try list.decodeNil() { continue }
                        if let pr = try? list.decode(PullRequest.self) { found.append(pr) } else { _ = try list.decode(Skip.self) }
                    }
                    nodes = found
                }
            }
            let review: Search
            let mine: Search
            /// Yours closed or merged in the last two days.
            let closed: Search?
        }
        struct Problem: Decodable { let message: String }
        let data: Data?
        let errors: [Problem]?
    }

    /// One search of GitHub, for the Search Pull Requests command.
    private struct SearchReply: Decodable {
        struct Data: Decodable { let found: Reply.Data.Search }
        let data: Data?
        let errors: [Reply.Problem]?
    }

    static let fragment = """
    fragment pr on PullRequest { number title url isDraft updatedAt state repository { nameWithOwner } author { login } \
    reviewDecision mergeable headRefName additions deletions comments { totalCount } commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } }
    """

    var toReview: [PullRequest] = []
    /// The token and server the lists were fetched with. A change means
    /// another account, so what was loaded for the old one is dropped.
    var credentials: String?
    /// Every review request listed since launch, so one that drops out of the
    /// age window and comes back with new activity isn't announced as new.
    var everRequested: Set<String> = []
    var mine: [PullRequest] = []
    /// How many pull requests each list matches on GitHub, which can be more
    /// than the 40 fetched.
    var reviewTotal = 0
    var mineTotal = 0
    var lastError: String?
    var updatedAt: Date?
    var loaded = false
    @Stored("tab") var tab = Tab.review.rawValue
    @Stored("includeTeams") var includeTeams = true
    @Stored("includeDrafts") var includeDrafts = false
    @Stored("notify") var notifyChanges = true
    @Stored("history") var history: [Double] = []
    /// When you last looked at each pull request (by URL), to mark new activity.
    @Stored("seen") var seen: [String: Date] = [:]
    @Stored("seenStarted") var seenStarted = false
    /// The last state each notification announced, by `<id> <topic>`, so a
    /// state GitHub briefly loses and finds again (mergeable going UNKNOWN
    /// after the base branch moves, checks going PENDING, search lagging
    /// behind a merge) is not announced twice.
    @Stored("announced") var announced: [String: String] = [:]
    /// Hidden until they change: URL to the update time they were snoozed at.
    @Stored("snoozed") var snoozed: [String: Date] = [:]
    @Stored("hiddenRepos") var hiddenRepos: [String] = []
    @Stored("showInbox") var showInbox = false
    /// GitHub Enterprise Server instead of github.com.
    @Stored("enterprise") var enterprise = false
    /// The Enterprise server, `https://github.example.com`, from GITHUB_ENTERPRISE_URL.
    var enterpriseServer: String?
    /// Only pull requests and issues updated in this many days; 0 for any age.
    @Stored("recentDays") var recentDays = 0
    var inbox: [InboxItem] = []
    var inboxError: String?
    /// Whether the inbox has loaded once, so an empty one still has a
    /// "before" to compare a new mention against.
    var inboxLoaded = false
    /// When the inbox was last fetched for the palette, and when Mark All as
    /// Read was first pressed (the second press within 10 s does it).
    var inboxFetched: Date?
    var markAllArmed: Date?
    /// The approval a first press asked for ("approve:<id>"), and when.
    var approveArmed: String?
    var approveArmedAt = Date.distantPast
    var recentlyClosed: [PullRequest] = []
    var issues: [Issue] = []
    var issuesError: String?
    var issuesLoaded = false
    @Stored("repos") var repos: [Repo] = []
    @Stored("reposLoaded") var reposLoaded: Date? = nil
    @Stored("recentRepos") var recentRepos: [String] = []
    @Stored("includeArchived") var includeArchived = false
    @Stored("cloneWith") var cloneWith = "SSH"
    var repoResults: [Repo] = []
    var reposError: String?
    /// When the repository list was last requested, success or not.
    var reposAttempted: Date?
    /// GitHub repository searches already made, by query, so typing back over
    /// the same text asks nothing; and why the last one failed.
    var repoSearches: [String: (items: [Repo], at: Date)] = [:]
    /// A cached search answers for this long.
    static let repoSearchTTL: TimeInterval = 300
    /// The token and server the repository list was last requested with: a
    /// change retries at once instead of waiting out the pause.
    var reposCredentials: String?
    var repoSearchError: String?
    var formError: String?
    var created: String?

    // MARK: Checks state

    /// Each pull request's checks and deployments, by URL, once fetched.
    var details: [String: PRDetails] = [:]
    /// Why fetching a pull request's checks failed, by URL.
    var detailErrors: [String: String] = [:]
    /// The pull request whose checks are open in the panel or window, and
    /// when it was opened: running checks are followed for 10 minutes.
    var expanded: String?
    var expandedAt: Date?
    /// Pull requests whose passing checks are all listed, not summed up.
    var showAllPassed: Set<String> = []
    /// When the lists were last fetched; the 20-second timer only follows
    /// open checks in between.
    var listsFetched: Date?
    /// A click on a pull request opens its checks (or the browser, as before).
    @Stored("clickShowsChecks") var clickShowsChecks = true
    /// Fetch the listed pull requests' checks in the background, so the
    /// palette's preview shows them as you move through the list.
    @Stored("previewChecks") var previewChecks = true
    /// What each pull request looked like (updated, rollup) when its checks
    /// were fetched; a change means they're worth fetching again.
    var checksStamp: [String: String] = [:]
    /// The re-run a first press asked for, and when.
    var rerunArmed: String?
    var rerunArmedAt = Date.distantPast

    /// github.com's API, or the Enterprise server's (`/api/v3` and `/api/graphql`).
    var apiBase: String { enterprise ? (enterpriseServer ?? "") + "/api/v3" : "https://api.github.com" }
    var graphqlURL: String { enterprise ? (enterpriseServer ?? "") + "/api/graphql" : "https://api.github.com/graphql" }

    /// Reads the Enterprise server once it's turned on. Only then, so people
    /// on github.com are never asked for it.
    func loadEnterpriseServer() async throws -> Bool {
        guard enterprise else { return true }
        if enterpriseServer == nil {
            var text = try await Stackbar.secret("GITHUB_ENTERPRISE_URL")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            while text.hasSuffix("/") { text.removeLast() }
            if text.hasSuffix("/api/v3") { text.removeLast("/api/v3".count) }
            if !text.isEmpty, !text.contains("://") { text = "https://" + text }
            enterpriseServer = text.isEmpty ? nil : text
        }
        return enterpriseServer != nil
    }

    /// Notes which account the next request is for. A token or server change
    /// starts over, so the new account's lists aren't announced as news.
    func noteCredentials(_ token: String) {
        let current = token + "|" + apiBase
        if let credentials, credentials != current { resetForNewAccount() }
        credentials = current
    }

    func resetForNewAccount() {
        everRequested = []; updatedAt = nil; toReview = []; mine = []; recentlyClosed = []; reviewTotal = 0; mineTotal = 0
        issues = []; issuesLoaded = false; issuesFetched = nil; inbox = []; inboxLoaded = false; inboxFetched = nil
        searchResults = []; searchedText = nil; repoSearches = [:]; repoResults = []
        repos = []; reposLoaded = nil; history = []; seenStarted = false; seen = [:]; snoozed = [:]; announced = [:]
        details = [:]; detailErrors = [:]; checksStamp = [:]; expanded = nil
    }

    /// Seconds a refresh request may take. The plugin handles one message at a
    /// time, so a slow GitHub holds up every click behind the refresh; a
    /// short limit keeps that wait short, and the next refresh tries again.
    static let refreshTimeout = 20.0

    func refresh() async throws {
        // The 20-second timer follows open checks; the lists every two minutes.
        if Stackbar.refreshReason == .interval, let listsFetched, Date().timeIntervalSince(listsFetched) < 115 {
            await followOpenChecks()
            return
        }
        listsFetched = Date()
        defer { loaded = true }
        guard try await loadEnterpriseServer() else {
            lastError = "Enter your GitHub Enterprise server (https://github.example.com) as GITHUB_ENTERPRISE_URL."
            return
        }
        guard let token = try await Stackbar.secret("GITHUB_TOKEN"), !token.isEmpty else {
            lastError = "Add a GitHub token to see your pull requests."
            return
        }
        noteCredentials(token)
        // The three requests run side by side: a refresh takes as long as the
        // slowest one, not all three, and a tab click waits for less.
        async let pullRequests: Void = loadPullRequests(token: token)
        async let notifications: Void = showInbox ? refreshInbox(token: token) : ()
        async let assigned: Void = loadIssues()
        _ = await (pullRequests, notifications, assigned)
        await followOpenChecks()
        if previewChecks { await prefetchChecks() }
    }

    /// Both lists and what closed lately, in one GraphQL request.
    func loadPullRequests(token: String) async {
        let requested = includeTeams ? "review-requested:@me" : "user-review-requested:@me"
        let draft = includeDrafts ? "" : " draft:false"
        let recent = recentCutoff.map { " updated:>=\(Self.day($0))" } ?? ""
        let since = Self.day(Date().addingTimeInterval(-2 * 86400))
        let query = """
        query { \
        review: search(query: "is:pr is:open archived:false \(requested)\(draft)\(recent) sort:updated-desc", type: ISSUE, first: 40) { issueCount nodes { ...pr } } \
        mine: search(query: "is:pr is:open archived:false author:@me\(recent) sort:updated-desc", type: ISSUE, first: 40) { issueCount nodes { ...pr } } \
        closed: search(query: "is:pr is:closed archived:false author:@me closed:>=\(since)", type: ISSUE, first: 20) { nodes { ...pr } } \
        } \(Self.fragment)
        """
        do {
            let body = try JSONEncoder().encode(["query": query])
            let response = try await Stackbar.http(HTTPRequest(url: graphqlURL, method: "POST", headers: [
                "Authorization": "Bearer \(token)", "Content-Type": "application/json", "Accept": "application/json",
            ], body: body, timeout: Self.refreshTimeout))
            guard (200..<300).contains(response.status) else {
                throw HostError(response.status == 401 ? "GitHub rejected the token (401); set a new GITHUB_TOKEN" : "GitHub answered \(response.status): \(String(decoding: response.body.prefix(200), as: UTF8.self))")
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let reply = try decoder.decode(Reply.self, from: response.body)
            guard let data = reply.data else { throw HostError(reply.errors?.map(\.message).joined(separator: "; ") ?? "GitHub sent no data") }
            update(review: data.review.nodes, mine: data.mine.nodes, closed: data.closed?.nodes ?? [])
            reviewTotal = data.review.issueCount ?? 0
            mineTotal = data.mine.issueCount ?? 0
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }

    /// A date as GitHub's search wants it: 2026-11-03.
    static func day(_ date: Date) -> String {
        ISO8601DateFormatter.string(from: date, timeZone: .gmt, formatOptions: [.withFullDate])
    }

    /// The choices for how far back to look, and the days each one means.
    static let ages: [(title: String, days: Int)] = [("Any age", 0), ("1 week", 7), ("2 weeks", 14), ("1 month", 30), ("3 months", 90)]

    /// The oldest update still shown, or nil to show any age.
    var recentCutoff: Date? {
        recentDays > 0 ? Date().addingTimeInterval(-Double(recentDays) * 86400) : nil
    }

    func isRecent(_ date: Date) -> Bool { recentCutoff.map { date >= $0 } ?? true }

    /// GitHub's notifications inbox. The REST API takes a classic token with
    /// the `notifications` scope; fine-grained tokens can't read it.
    func refreshInbox(token: String) async {
        do {
            let response = try await Stackbar.http(HTTPRequest(url: apiBase + "/notifications?per_page=40", headers: [
                "Authorization": "Bearer \(token)", "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28",
            ], timeout: Self.refreshTimeout))
            guard (200..<300).contains(response.status) else {
                throw HostError(response.status == 403 || response.status == 404
                    ? "GitHub won't share notifications with this token. The inbox needs a classic token with the notifications scope."
                    : "GitHub answered \(response.status) for notifications")
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let items = try decoder.decode([InboxItem].self, from: response.body)
            if notifyChanges, inboxLoaded {
                let known = Set(inbox.map(\.id))
                let mentions = items.filter { $0.unread && !known.contains($0.id) && ($0.reason == "mention" || $0.reason == "team_mention") }
                if mentions.count > 3 {
                    Stackbar.notify("\(mentions.count) new mentions on GitHub", body: mentions.prefix(3).map { $0.subject.title }.joined(separator: "\n"))
                } else {
                    for item in mentions {
                        Stackbar.notify("Mentioned: \(item.subject.title)", body: item.repository.full_name, actions: [NotificationAction("Open", url: item.webURL)])
                    }
                }
            }
            inbox = items.sorted { $0.updated_at > $1.updated_at }
            inboxLoaded = true
            inboxError = nil
        } catch {
            inboxError = "\(error)"
        }
    }

    /// The inbox for the palette, which asks on every keystroke. A fetch less
    /// than `maxAge` old is kept, and a failed one waits 30 s.
    func loadInbox(maxAge: TimeInterval) async {
        if let at = inboxFetched, Date().timeIntervalSince(at) < (inboxError == nil ? maxAge : max(maxAge, 30)) { return }
        guard (try? await loadEnterpriseServer()) == true else {
            inboxError = "Enter your GitHub Enterprise server as GITHUB_ENTERPRISE_URL."
            inboxFetched = Date()
            return
        }
        guard let token = try? await Stackbar.secret("GITHUB_TOKEN"), !token.isEmpty else {
            inboxError = "Add a GitHub token first"
            return
        }
        noteCredentials(token)
        await refreshInbox(token: token)
        inboxFetched = Date()
    }

    /// Marks notifications as read on GitHub, up to the last fetch: GitHub
    /// marks the whole account unless told otherwise, and anything that arrived
    /// since would be marked read unseen. The first press only asks for a second
    /// one within 10 seconds, as the other bulk actions do.
    func markAllRead() async {
        guard let armed = markAllArmed, Date().timeIntervalSince(armed) < 10 else {
            markAllArmed = Date()
            // The inbox loads up to 40, so 40 may be only some of them.
            let scope = inbox.count >= 40 ? "all your GitHub notifications" : "\(inbox.count)"
            Stackbar.hud("Press again within 10 s to mark \(scope) as read")
            return
        }
        markAllArmed = nil
        let count = inbox.count
        do {
            guard let token = try await Stackbar.secret("GITHUB_TOKEN"), !token.isEmpty else { throw HostError("Add a GitHub token first") }
            let stamp = ISO8601DateFormatter().string(from: inboxFetched ?? updatedAt ?? Date())
            let body = try JSONSerialization.data(withJSONObject: ["read": true, "last_read_at": stamp])
            let response = try await Stackbar.http(HTTPRequest(url: apiBase + "/notifications", method: "PUT", headers: [
                "Authorization": "Bearer \(token)", "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28",
                "Content-Type": "application/json",
            ], body: body, timeout: Self.refreshTimeout))
            guard response.status == 202 || response.status == 205 else { throw HostError("GitHub answered \(response.status)") }
            inbox = []
            Stackbar.hud("Marked \(count) as read")
        } catch {
            Stackbar.hud("Couldn't mark them as read: \(error)", isError: true)
        }
    }

    func markRead(_ item: InboxItem) async {
        do {
            guard let token = try await Stackbar.secret("GITHUB_TOKEN"), !token.isEmpty else { throw HostError("Add a GitHub token first") }
            let response = try await Stackbar.http(HTTPRequest(url: apiBase + "/notifications/threads/\(item.id)", method: "PATCH", headers: [
                "Authorization": "Bearer \(token)", "Accept": "application/vnd.github+json",
            ], timeout: Self.refreshTimeout))
            guard (200..<300).contains(response.status) else { throw HostError("GitHub answered \(response.status)") }
            inbox.removeAll { $0.id == item.id }
        } catch {
            Stackbar.hud("Couldn't mark it as read: \(error)", isError: true)
        }
    }

    func inboxRow(_ item: InboxItem) -> Row {
        var row = Row(item.subject.title, subtitle: [item.repository.full_name, item.reasonText, Self.ago(item.updated_at)].joined(separator: " · "), symbol: item.symbol, key: "inbox-\(item.id)")
        if item.unread { row = row.badge("Unread", role: .accent) }
        if item.reason == "mention" || item.reason == "team_mention" { row = row.badge("@", role: .warning) }
        return row.action("Open", shortcut: "cmd+return") {
            Stackbar.open(item.webURL)
            await self.markRead(item)
        }
        .action("Mark as read", shortcut: "cmd+u") { await self.markRead(item) }
        .action("Copy link") { Stackbar.copy(item.webURL) }
    }

    /// Takes the new lists, telling the user what changed since last time.
    func update(review: [PullRequest], mine fetchedMine: [PullRequest], closed: [PullRequest] = []) {
        // Search can list a PR that just closed under both queries for a refresh or two.
        let closedIDs = Set(closed.map(\.id))
        let newMine = fetchedMine.filter { !closedIDs.contains($0.id) }
        let notifying = notifyChanges && updatedAt != nil
        if notifying {
            let wasOpen = Set(mine.map(\.id))
            var ended: [PullRequest] = []
            for pr in closed where wasOpen.contains(pr.id) && announce(pr, "closed", as: pr.state ?? "CLOSED") { ended.append(pr) }
            if ended.count > 3 {
                Stackbar.notify("\(ended.count) of your pull requests merged or closed", body: ended.prefix(3).map(\.title).joined(separator: "\n"))
            } else {
                for pr in ended {
                    Stackbar.notify(pr.state == "MERGED" ? "Merged: \(pr.title)" : "Closed: \(pr.title)", body: pr.id, actions: [NotificationAction("Open", url: pr.url)])
                }
            }
            let added = review.filter { !everRequested.contains($0.id) }
            if added.count == 1, let pr = added.first {
                Stackbar.notify("Review requested: \(pr.title)", body: "\(pr.id) by \(pr.author?.login ?? "someone")", actions: [NotificationAction("Review", url: pr.url + "/files")])
            } else if added.count > 1 {
                Stackbar.notify("\(added.count) new review requests", body: added.map(\.title).prefix(3).joined(separator: "\n"))
            }
        }
        let before = Set(mine.map(\.id))
        for pr in newMine {
            // A PR seen for the first time records its state without a notification.
            let tell = notifying && before.contains(pr.id)
            if let decision = pr.reviewDecision, announce(pr, "review", as: decision), tell {
                if decision == "APPROVED" {
                    Stackbar.notify("Approved: \(pr.title)", body: pr.id, actions: [NotificationAction("Open", url: pr.url)])
                } else if decision == "CHANGES_REQUESTED" {
                    Stackbar.notify("Changes requested: \(pr.title)", body: pr.id, actions: [NotificationAction("Open", url: pr.url)])
                }
            }
            // An unknown merge state passes (GitHub recomputes it whenever the
            // base moves); running checks reset, so a new push that goes green is news.
            let outcome: String? = switch pr.checks {
            case "PENDING", "EXPECTED": "running"
            case _ where pr.checksFailed: "failed"
            case _ where pr.readyToMerge: "ready"
            case "SUCCESS" where pr.mergeable == "UNKNOWN": nil
            default: "blocked"
            }
            if let outcome, announce(pr, "checks", as: outcome), tell {
                if outcome == "failed" {
                    Stackbar.notify("Checks failed: \(pr.title)", body: pr.id, actions: [NotificationAction("See checks", url: pr.url + "/checks")])
                } else if outcome == "ready" {
                    Stackbar.notify("Ready to merge: \(pr.title)", body: pr.id, actions: [NotificationAction("Open", url: pr.url)])
                }
            }
        }
        let tracked = Set((newMine + closed).map(\.id))
        // Each assignment to a stored property rewrites the plugin's whole
        // file, so only assign what changed.
        let keptAnnounced = announced.filter { tracked.contains(String($0.key.split(separator: " ").first ?? "")) }
        if keptAnnounced != announced { announced = keptAnnounced }
        everRequested.formUnion(review.map(\.id))
        recentlyClosed = closed.sorted { $0.updatedAt > $1.updatedAt }
        toReview = review.sorted { $0.updatedAt > $1.updatedAt }
        mine = newMine.sorted { $0.updatedAt > $1.updatedAt }
        let current = Set((toReview + mine).map(\.url))
        if !seenStarted {
            seenStarted = true
            // First run: what is already there isn't news.
            seen = Dictionary((toReview + mine).map { ($0.url, $0.updatedAt) }, uniquingKeysWith: { first, _ in first })
        } else {
            let kept = seen.filter { current.contains($0.key) }
            if kept != seen { seen = kept }
        }
        let keptSnoozed = snoozed.filter { current.contains($0.key) }
        if keptSnoozed != snoozed { snoozed = keptSnoozed }
        history = Array((history + [Double(review.count)]).suffix(48))
        updatedAt = Date()
    }

    // MARK: Filtering and attention

    func isShown(_ pr: PullRequest) -> Bool {
        // Also checked here, so a new setting applies before the next fetch
        // and a PR ages out between fetches.
        if !isRecent(pr.updatedAt) { return false }
        if hiddenRepos.contains(pr.repo) { return false }
        if let at = snoozed[pr.url], pr.updatedAt <= at { return false }
        return true
    }

    var shownReview: [PullRequest] { toReview.filter(isShown) }
    var shownMine: [PullRequest] { mine.filter(isShown) }
    /// Snoozed or in a hidden repository; not the ones too old to show.
    var hiddenCount: Int {
        (toReview + mine).filter { isRecent($0.updatedAt) }.count - shownReview.count - shownMine.count
    }
    var shownIssues: [Issue] { issues.filter { isRecent($0.updated_at) } }

    func isNew(_ pr: PullRequest) -> Bool {
        guard let at = seen[pr.url] else { return true }
        return pr.updatedAt > at
    }

    func markSeen(_ pr: PullRequest) { seen[pr.url] = pr.updatedAt }

    /// Every listed pull request as seen, in one write instead of one each.
    func markAllSeen() {
        var marked = seen
        for pr in toReview + mine { marked[pr.url] = pr.updatedAt }
        seen = marked
    }

    /// Records `state` as the last one announced about `pr`'s `topic`, and
    /// says whether it is a change from what was announced before.
    func announce(_ pr: PullRequest, _ topic: String, as state: String) -> Bool {
        let key = "\(pr.id) \(topic)"
        guard announced[key] != state else { return false }
        announced[key] = state
        return true
    }

    func open(_ pr: PullRequest, path: String = "") {
        markSeen(pr)
        Stackbar.open(pr.url + path)
    }

    /// Approves a pull request, then refreshes the lists so it leaves the queue.
    /// The first press only asks for a second one within 10 seconds, as the
    /// other bulk actions do, so a stray click doesn't approve anything.
    func approve(_ pr: PullRequest) async {
        let id = "approve:\(pr.id)"
        guard approveArmed == id, Date().timeIntervalSince(approveArmedAt) < 10 else {
            approveArmed = id
            approveArmedAt = Date()
            Stackbar.hud("Press Approve again within 10 s to approve \(pr.id)")
            return
        }
        approveArmed = nil
        do {
            _ = try await rest("/repos/\(pr.repo)/pulls/\(pr.number)/reviews", method: "POST", body: JSONSerialization.data(withJSONObject: ["event": "APPROVE"]), timeout: Self.refreshTimeout)
            Stackbar.hud("Approved \(pr.id)")
            try? await refresh()
        } catch {
            Stackbar.hud("\(error)", isError: true)
        }
    }

    // MARK: Issues and repositories (REST)

    static let restDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func rest(_ path: String, method: String = "GET", body: Data? = nil, timeout: Double = 30) async throws -> Data {
        guard try await loadEnterpriseServer() else { throw HostError("Enter your GitHub Enterprise server as GITHUB_ENTERPRISE_URL") }
        guard let token = try await Stackbar.secret("GITHUB_TOKEN"), !token.isEmpty else {
            throw HostError("Add a GitHub token (GITHUB_TOKEN) first")
        }
        noteCredentials(token)
        let response = try await Stackbar.http(HTTPRequest(url: apiBase + path, method: method, headers: [
            "Authorization": "Bearer \(token)",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "Content-Type": "application/json",
        ], body: body, timeout: timeout))
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

    /// When the assigned issues were last fetched, for `loadIssues(maxAge:)`.
    var issuesFetched: Date?

    /// Open issues assigned to you, telling you about new ones. With a
    /// `maxAge`, a list fetched more recently than that is kept: the palette
    /// view calls this on every keystroke and filters the list locally.
    func loadIssues(maxAge: TimeInterval = 0) async {
        // While the last fetch failed, wait 30 s between tries instead of
        // retrying on every keystroke.
        if maxAge > 0, let at = issuesFetched, Date().timeIntervalSince(at) < (issuesError == nil ? maxAge : max(maxAge, 30)) { return }
        issuesFetched = Date()
        do {
            // Every assigned issue, not only recent ones: an old one that
            // changes must not look newly assigned. `shownIssues` filters by age.
            // The endpoint lists pull requests too, so read up to three pages
            // of 100 and drop them.
            var all: [Issue] = []
            for page in 1...3 {
                let data = try await rest("/issues?filter=assigned&state=open&per_page=100&page=\(page)&sort=updated", timeout: Self.refreshTimeout)
                let batch = try Self.restDecoder.decode([Issue].self, from: data)
                all += batch.filter { $0.pull_request == nil }
                if batch.count < 100 { break }
            }
            let fresh = all
            if notifyChanges, issuesLoaded {
                let known = Set(issues.map(\.id))
                let added = fresh.filter { !known.contains($0.id) }
                if added.count == 1, let issue = added.first {
                    Stackbar.notify("Assigned: \(issue.title)", body: issue.reference, actions: [NotificationAction("Open", url: issue.html_url)])
                } else if added.count > 1 {
                    Stackbar.notify("\(added.count) issues assigned to you", body: added.prefix(3).map(\.title).joined(separator: "\n"))
                }
            }
            issues = fresh
            issuesError = nil
            issuesLoaded = true
        } catch {
            issuesError = "\(error)"
        }
    }

    /// Your repositories and your organizations', most recently pushed
    /// first; three pages of 100 at most. Kept for six hours.
    func loadRepos(force: Bool = false) async {
        if !force, !repos.isEmpty, let at = reposLoaded, Date().timeIntervalSince(at) < 6 * 3600 { return }
        // An empty account or an unreachable GitHub never fills the cache;
        // the palette asks on every keystroke, so wait between tries, unless
        // the token or server changed since the last one.
        let token = (try? await Stackbar.secret("GITHUB_TOKEN")) ?? ""
        let credentials = token + "|" + apiBase
        if !force, credentials == reposCredentials, let at = reposAttempted, Date().timeIntervalSince(at) < 15 { return }
        reposCredentials = credentials
        reposAttempted = Date()
        do {
            var all: [Repo] = []
            for page in 1...3 {
                let data = try await rest("/user/repos?sort=pushed&per_page=100&page=\(page)&affiliation=owner,collaborator,organization_member")
                let batch = try Self.restDecoder.decode([Repo].self, from: data)
                all += batch
                if batch.count < 100 { break }
            }
            repos = all
            reposLoaded = Date()
            reposError = nil
        } catch {
            reposError = "\(error)"
        }
    }

    /// GitHub search for repositories you don't have, once your own run short.
    func searchRepos(_ text: String) async {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard query.count >= 3, matchingRepos(query).count < 5 else {
            repoResults = []
            repoSearchError = nil
            return
        }
        if let known = repoSearches[query], Date().timeIntervalSince(known.at) < Self.repoSearchTTL {
            repoResults = known.items
            repoSearchError = nil
            return
        }
        struct Reply: Decodable { let items: [Repo] }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
        do {
            let items = try Self.restDecoder.decode(Reply.self, from: try await rest("/search/repositories?q=\(encoded)&per_page=10")).items
            if repoSearches.count >= 50 { repoSearches.removeAll() }
            repoSearches[query] = (items, Date())
            repoResults = items
            repoSearchError = nil
        } catch {
            // Not cached, so the next keystroke may succeed; but say why
            // nothing came back instead of looking like "no such repository".
            repoResults = []
            repoSearchError = "GitHub search failed: \(error)"
        }
    }

    func matchingRepos(_ text: String) -> [Repo] {
        let words = text.lowercased().split(separator: " ")
        return shownRepos.filter { repo in words.allSatisfy { repo.full_name.lowercased().contains($0) } }
    }

    /// Fetched pull requests named by `#123` or `repo#123` (owner optional).
    func rootPulls(_ text: String) -> [PullRequest] {
        let parts = text.trimmingCharacters(in: .whitespaces).lowercased().split(separator: "#", omittingEmptySubsequences: false)
        guard parts.count == 2, let number = Int(parts[1]) else { return [] }
        let repo = String(parts[0])
        var seen = Set<String>()
        return (toReview + mine).filter { pr in
            pr.number == number && (repo.isEmpty || pr.repository.nameWithOwner.lowercased().hasSuffix(repo)) && seen.insert(pr.url).inserted
        }
    }

    /// Saved repositories whose name contains `owner/re…`, recent first.
    func rootRepos(_ text: String) -> [Repo] {
        let typed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard typed.contains("/"), !typed.contains("#") else { return [] }
        return Array(orderedRepos.filter { $0.full_name.lowercased().contains(typed) }.prefix(3))
    }

    var shownRepos: [Repo] { repos.filter { includeArchived || !$0.archived } }

    /// Recently opened first, then most recently pushed.
    var orderedRepos: [Repo] {
        let rank = Dictionary(recentRepos.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return shownRepos.sorted { (rank[$0.full_name] ?? Int.max, $0.pushed_at.map { -$0.timeIntervalSince1970 } ?? 0) < (rank[$1.full_name] ?? Int.max, $1.pushed_at.map { -$0.timeIntervalSince1970 } ?? 0) }
    }

    func opened(_ repo: Repo) {
        recentRepos = Array(([repo.full_name] + recentRepos.filter { $0 != repo.full_name }).prefix(10))
    }

    func repoRow(_ repo: Repo) -> Row {
        let fallback = "★ \(repo.stargazers_count) · \(repo.open_issues_count) open issue\(repo.open_issues_count == 1 ? "" : "s")"
        var row = Row(repo.full_name, subtitle: repo.description.flatMap { $0.isEmpty ? nil : $0 } ?? fallback, symbol: repo.private ? "lock" : "book.closed", key: "repo-\(repo.id)")
        if repo.archived { row = row.badge("archived") } else if repo.fork { row = row.badge("fork") }
        return row
            .action("Open") { self.opened(repo); Stackbar.open(repo.html_url) }
            .action("Pull Requests", shortcut: "cmd+p") { self.opened(repo); Stackbar.open(repo.html_url + "/pulls") }
            .action("Issues", shortcut: "cmd+i") { self.opened(repo); Stackbar.open(repo.html_url + "/issues") }
            .action("Actions", shortcut: "cmd+shift+a") { self.opened(repo); Stackbar.open(repo.html_url + "/actions") }
            .action("Copy Clone URL", shortcut: "cmd+shift+c") { Stackbar.copy(self.cloneWith == "HTTPS" ? repo.clone_url : repo.ssh_url) }
            .action("Copy URL", shortcut: "cmd+c") { Stackbar.copy(repo.html_url) }
            .navigate("New Issue", to: "create-issue", arguments: ["repo": repo.full_name], shortcut: "cmd+n")
    }

    func issueRow(_ issue: Issue) -> Row {
        var row = Row(issue.title, subtitle: "\(issue.reference) · \(Self.ago(issue.updated_at))", symbol: "smallcircle.filled.circle", key: "issue-\(issue.id)")
        if let label = issue.labels.first { row = row.badge(label.name) }
        return row
            .action("Open", shortcut: "cmd+return") { Stackbar.open(issue.html_url) }
            .action("Copy Link", shortcut: "cmd+c") { Stackbar.copy(issue.html_url) }
            .action("Copy Reference", shortcut: "cmd+shift+c") { Stackbar.copy(issue.reference) }
    }

    @ViewBuilder func issueForm(repo: String?) -> ViewContent {
        let names = shownRepos.filter(\.has_issues).map(\.full_name)
        if names.isEmpty {
            ContentUnavailableView("No repositories yet", symbol: "book.closed", message: reposError ?? "Add a GitHub token, then try again.")
        } else {
            Form(submit: "Create Issue", key: "issue") {
                FormField.picker("Repository", name: "repo", options: names, selection: repo.flatMap { names.contains($0) ? $0 : nil } ?? recentRepos.first { names.contains($0) } ?? names.first)
                FormField.text("Title", name: "title", error: formError)
                FormField.multiline("Description", name: "body", placeholder: "Markdown")
            } onSubmit: { values in
                try await self.createIssue(values)
            }
            if let created { Banner(created, symbol: "checkmark.circle.fill", theme: .success) }
        }
    }

    func createIssue(_ values: [String: EventValue]) async throws {
        let title = (values.string("title") ?? "").trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { formError = "Give it a title"; return }
        guard let repo = values.string("repo"), repo.split(separator: "/").count == 2 else { formError = "Pick a repository"; return }
        formError = nil
        let body = try JSONSerialization.data(withJSONObject: ["title": title, "body": values.string("body") ?? ""])
        do {
            let data = try await rest("/repos/\(repo)/issues", method: "POST", body: body)
            struct Created: Decodable { let html_url: String; let number: Int }
            let issue = try Self.restDecoder.decode(Created.self, from: data)
            created = "Created \(repo)#\(issue.number)"
            Stackbar.open(issue.html_url)
        } catch {
            formError = "\(error)"
        }
    }

    // MARK: Words

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 3600 { return "\(max(1, Int(seconds / 60)))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
    }

    func row(_ pr: PullRequest, showAuthor: Bool, palette: Bool = false) -> Row {
        let size = pr.additions.map { "+\($0) −\(pr.deletions ?? 0)" }
        let comments = (pr.comments?.totalCount ?? 0) >= 5 ? "\(pr.comments?.totalCount ?? 0) comments" : nil
        let subtitle = [pr.id, showAuthor ? pr.author.map { "by \($0.login)" } : nil, size, comments, Self.ago(pr.updatedAt)].compactMap { $0 }.joined(separator: " · ")
        var row = Row(pr.title, subtitle: subtitle, symbol: isNew(pr) ? "circle.fill" : pr.isDraft ? "pencil.circle" : "arrow.triangle.pull", key: pr.url)
        for badge in badges(pr, mine: !showAuthor).prefix(2) { row = row.badge(badge.text, role: badge.role) }
        if clickShowsChecks && !palette {
            row = row.action(expanded == pr.url ? "Hide checks" : "Show checks") { await self.toggleChecks(pr) }
        }
        row = row.action("Open in browser", shortcut: "cmd+return") { self.open(pr) }
        if !clickShowsChecks && !palette {
            row = row.action(expanded == pr.url ? "Hide checks" : "Show checks", shortcut: "cmd+i") { await self.toggleChecks(pr) }
        }
        if palette {
            row = row.navigate("Checks and deployments", to: "checks", arguments: ["url": pr.url], shortcut: "cmd+i")
        }
        if let summary = details[pr.url]?.summary {
            row = row.preview(text: details[pr.url].map { checksText(pr, $0) }, caption: summary)
        }
        row = row.action("Open files changed") { self.open(pr, path: "/files") }
            .action(isNew(pr) ? "Mark as seen" : "Mark as new", shortcut: "cmd+u") {
                if self.isNew(pr) { self.markSeen(pr) } else { self.seen[pr.url] = .distantPast }
            }
            .action("Snooze until it changes", shortcut: "cmd+s") { self.snoozed[pr.url] = pr.updatedAt }
            .action("Hide \(pr.repo)") { if !self.hiddenRepos.contains(pr.repo) { self.hiddenRepos.append(pr.repo) } }
            .action("Copy link") { Stackbar.copy(pr.url) }
        if toReview.contains(where: { $0.id == pr.id }) {
            row = row.action("Approve", shortcut: "cmd+shift+a") { await self.approve(pr) }
        }
        if let branch = pr.headRefName {
            row = row.action("Copy branch name") { Stackbar.copy(branch) }
        }
        return row.action("Copy as Markdown") { Stackbar.copy("[\(pr.title) (\(pr.id))](\(pr.url))") }
    }

    /// What a pull request needs you to know, most urgent first. Green is
    /// the normal state, so "checks pass" is never said on its own.
    func badges(_ pr: PullRequest, mine: Bool) -> [(text: String, role: Role)] {
        var found: [(String, Role)] = []
        if pr.checksFailed { found.append(("Checks fail", .critical)) }
        if pr.reviewDecision == "CHANGES_REQUESTED" { found.append(("Changes requested", .critical)) }
        if pr.mergeable == "CONFLICTING" { found.append(("Conflicts", .warning)) }
        if mine, pr.readyToMerge { found.append(("Ready to merge", .success)) } else if pr.reviewDecision == "APPROVED" { found.append(("Approved", .success)) }
        if pr.checks == "PENDING" || pr.checks == "EXPECTED" { found.append(("Checks running", .warning)) }
        if pr.isDraft { found.append(("Draft", .secondary)) }
        return found
    }

    var failingMine: Int { shownMine.filter(\.checksFailed).count }

    let theme = Theme.violet

    // MARK: Surfaces

    var menuBar: ViewContent {
        if lastError != nil && toReview.isEmpty && mine.isEmpty {
            Label("", symbol: "arrow.triangle.pull").role(.warning)
        } else if failingMine > 0 {
            Label("\(shownReview.count) · \(failingMine)✕", symbol: "arrow.triangle.pull").role(.critical)
        } else if shownReview.isEmpty {
            Label("", symbol: "arrow.triangle.pull").role(.secondary)
        } else {
            Label("\(shownReview.count)", symbol: "arrow.triangle.pull")
        }
    }

    var headline: String {
        if failingMine > 0 { return "\(failingMine) PR\(failingMine == 1 ? "" : "s") failing checks" }
        if !shownReview.isEmpty { return "\(shownReview.count) waiting on you" }
        return "All caught up"
    }

    var panel: ViewContent {
        VStack(spacing: Space.m) {
            if !loaded {
                PanelHeader("Pull requests", subtitle: "Checking…", symbol: "arrow.triangle.pull", theme: theme)
            } else if lastError != nil, toReview.isEmpty, mine.isEmpty, updatedAt == nil {
                problemState
            } else {
                PanelHeader(headline, subtitle: "\(shownMine.count) of yours open" + (updatedAt.map { " · updated \($0.formatted(date: .omitted, time: .shortened))" } ?? ""), symbol: "arrow.triangle.pull", theme: theme) {
                    if (shownReview + shownMine).contains(where: isNew) {
                        IconButton("checkmark.circle", label: "Mark all as seen", theme: theme, prominence: .tinted) { self.markAllSeen() }
                    }
                }
                HeroCard(theme: theme, look: .glow) {
                    HStack(spacing: Space.l) {
                        HeroStat("To review", value: "\(shownReview.count)", theme: theme, live: !shownReview.isEmpty)
                        HeroStat("Mine", value: "\(shownMine.count)", theme: .neutral, symbol: "person.fill")
                        if failingMine > 0 {
                            HeroStat("Failing", value: "\(failingMine)", theme: .critical, symbol: "xmark.octagon.fill")
                        } else {
                            HeroStat("Ready", value: "\(shownMine.filter(\.readyToMerge).count)", theme: .success, symbol: "checkmark.seal.fill")
                        }
                        Spacer()
                    }
                }
                Picker("Show", options: tabs.map(label), selection: label(currentTab), style: .segmented) { chosen in
                    self.tab = (self.tabs.first { self.label($0) == chosen } ?? .review).rawValue
                }
                if let lastError { Banner(lastError) }
                if currentTab == .inbox {
                    if let inboxError { Banner(inboxError) }
                    if inbox.isEmpty {
                        if inboxError == nil { EmptyState("Inbox zero", symbol: "tray", message: "No GitHub notifications.", theme: .success) }
                    } else {
                        ActionButton("Mark All as Read", symbol: "checkmark.circle", theme: theme, key: "inbox-mark-all") { await self.markAllRead() }
                        List(inbox, searchable: true) { item in inboxRow(item) }
                    }
                } else if currentTab == .issues {
                    if let issuesError { Banner(issuesError) }
                    if shownIssues.isEmpty {
                        if issuesError == nil { EmptyState("No issues assigned", symbol: "checkmark", message: "Open issues assigned to you show up here.", theme: .success) }
                    } else {
                        List(shownIssues, searchable: true) { issue in issueRow(issue) }
                    }
                } else if currentTab == .mine {
                    list(shownMine, showAuthor: false, empty: ("Nothing of yours open", "Pull requests you open show up here."))
                    if mineTotal > 40 { Text("Showing the 40 most recently updated of \(mineTotal).").style(.caption).role(.secondary) }
                } else {
                    list(shownReview, showAuthor: true, empty: ("No reviews waiting", "Pull requests that ask for your review show up here."))
                    if reviewTotal > 40 { Text("Showing the 40 most recently updated of \(reviewTotal).").style(.caption).role(.secondary) }
                }
                if hiddenCount > 0 || !hiddenRepos.isEmpty {
                    ActionButton("Show \(hiddenCount) hidden", symbol: "eye", theme: theme, key: "unhide") {
                        self.snoozed = [:]
                        self.hiddenRepos = []
                    }
                }
            }
        }
    }

    /// What to show instead of the lists when none have loaded: how to add a
    /// token, or why GitHub can't be reached.
    @ViewBuilder var problemState: ViewContent {
        if let lastError, lastError.contains("Add a GitHub token") {
            EmptyState("Paste a GitHub token above", symbol: "key.fill", message: "A fine-grained token with read access to pull requests, issues and metadata. Add write access to issues to create them from the palette.", theme: theme)
        } else {
            EmptyState("Can't reach GitHub", symbol: "exclamationmark.triangle.fill", message: lastError, theme: .critical) {
                ActionButton("Try Again", symbol: "arrow.clockwise", theme: theme) { try await self.refresh() }
            }
        }
    }

    /// Fetches again after a setting changed what is fetched. Pull requests
    /// the new search brings in were there all along, so they are not
    /// announced as new review requests.
    func refetch() async throws {
        everRequested = []
        updatedAt = nil
        try await refresh()
    }

    /// Stackbar's Settings window, so the panel stays about the pull requests.
    var settings: ViewContent {
        Section("What to show") {
            Toggle("Include requests to my teams", isOn: includeTeams) { on in
                self.includeTeams = on
                try await self.refetch()
            }
            Toggle("Include drafts to review", isOn: includeDrafts) { on in
                self.includeDrafts = on
                try await self.refetch()
            }
            Picker("Updated within", options: Self.ages.map(\.title), selection: (Self.ages.first { $0.days == recentDays } ?? Self.ages[0]).title) { chosen in
                self.recentDays = Self.ages.first { $0.title == chosen }?.days ?? 0
                try await self.refetch()
            }
            Text("Pull requests and issues nobody has touched for longer stay out of the lists, and fewer to fetch makes refreshing quicker.").style(.caption).role(.secondary)
        }
        Section("Clicking a pull request") {
            Picker("Click", options: ["Shows its checks", "Opens it in the browser"], selection: clickShowsChecks ? "Shows its checks" : "Opens it in the browser") { chosen in
                self.clickShowsChecks = chosen == "Shows its checks"
            }
            Text("Checks open under the pull request with why they failed, its deployments, and Re-run. ⌘↩ always opens the browser. Re-running needs a token with Actions write access.").style(.caption).role(.secondary)
            Toggle("Show checks in the palette's preview", isOn: previewChecks) { self.previewChecks = $0 }
            Text("Fetches the checks of your listed pull requests in the background, only for those whose checks changed, so the preview beside the palette shows them as you move through the list.").style(.caption).role(.secondary)
        }
        Section("Notifications") {
            Toggle("Notify me about changes", isOn: notifyChanges) { self.notifyChanges = $0 }
            Text("Review requests, approvals, changes requested, failing checks, ready to merge, merged and closed, and mentions in the inbox.").style(.caption).role(.secondary)
        }
        Section("Server") {
            Toggle("Use GitHub Enterprise Server", isOn: enterprise) { on in
                self.enterprise = on
                self.enterpriseServer = nil
                try await self.refetch()
            }
            if enterprise {
                LabeledContent("Server", value: enterpriseServer ?? "Not set: enter GITHUB_ENTERPRISE_URL")
                Text("Enter your server's address (https://github.example.com) as GITHUB_ENTERPRISE_URL, and a token from that server as GITHUB_TOKEN. Requests go to that server and no other.").style(.caption).role(.secondary)
            }
        }
        Section("GitHub inbox") {
            Toggle("Show the notifications inbox", isOn: showInbox) { on in
                self.showInbox = on
                if on { try await self.refresh() } else { self.inbox = [] }
            }
            Text("Mentions, issues and everything else GitHub notifies you about. Needs a classic token with the notifications scope.").style(.caption).role(.secondary)
            if let inboxError { Text(inboxError).style(.caption).role(.warning) }
        }
        Section("Repositories") {
            LabeledContent("Loaded", value: "\(repos.count)")
            Toggle("Include archived", isOn: includeArchived) { self.includeArchived = $0 }
            Picker("Copy clone URLs as", options: ["SSH", "HTTPS"], selection: cloneWith) { self.cloneWith = $0 }
            Button("Reload", symbol: "arrow.clockwise") { await self.loadRepos(force: true) }
            Text("Search GitHub Repositories in the palette opens any of them, or its pull requests, issues or Actions. Creating issues needs a token with write access to issues.").style(.caption).role(.secondary)
        }
        Section("Hidden repositories") {
            if hiddenRepos.isEmpty { Text("None. Hide one from a pull request's menu.").role(.secondary) }
            ForEach(hiddenRepos) { repo in
                Row(repo, symbol: "eye.slash", key: "hidden-\(repo)").action("Show again") { self.hiddenRepos.removeAll { $0 == repo } }
            }
        }
    }

    /// Both lists side by side in sections, since a window has the room.
    var window: ViewContent {
        if !loaded {
            PanelHeader("Pull requests", subtitle: "Checking…", symbol: "arrow.triangle.pull", theme: theme)
        } else if lastError != nil, toReview.isEmpty, mine.isEmpty, updatedAt == nil {
            problemState
        } else {
            windowContent
        }
    }

    @ViewBuilder var windowContent: ViewContent {
        if let lastError { Banner(lastError) }
        List(searchable: true) {
            Section("Waiting on your review (\(shownReview.count))") {
                ForEach(shownReview) { pr in rowWithChecks(pr, showAuthor: true) }
            }
            Section("Yours (\(shownMine.count))") {
                ForEach(shownMine) { pr in rowWithChecks(pr, showAuthor: false) }
            }
        }
        if !recentlyClosed.isEmpty {
            Section("Closed in the last two days") {
                ForEach(recentlyClosed) { pr in
                    Row(pr.title, subtitle: "\(pr.id) · \(Self.ago(pr.updatedAt))", symbol: pr.state == "MERGED" ? "arrow.triangle.merge" : "xmark.circle", key: "closed-\(pr.url)")
                        .badge(pr.state == "MERGED" ? "Merged" : "Closed", role: pr.state == "MERGED" ? .success : .secondary)
                        .action("Open in browser") { Stackbar.open(pr.url) }
                }
            }
        }
        if !(shownReview + shownMine).isEmpty {
            Section("Overview") {
                let states = mineByState
                if !states.isEmpty {
                    Chart("Your pull requests", values: states.map { Double($0.count) }, kind: .donut, role: .success, labels: states.map(\.name))
                }
                let ages = reviewAges
                if ages.contains(where: { $0 > 0 }) {
                    Chart("How long reviews have waited", values: ages, kind: .bar, role: ages.last ?? 0 > 0 ? .warning : .accent, labels: ["< 1 day", "1–3 days", "3–7 days", "> 1 week"])
                }
                let repos = Dictionary(grouping: shownReview, by: \.repo).map { (name: $0.key, count: $0.value.count) }.sorted { $0.count > $1.count }.prefix(6)
                if repos.count > 1 {
                    Chart("To review, by repository", values: repos.map { Double($0.count) }, kind: .donut, labels: repos.map { $0.name.split(separator: "/").last.map(String.init) ?? $0.name })
                }
                if history.count > 1 {
                    Chart("Review queue over time", values: history, kind: .area)
                }
            }
        }
    }

    /// Your open pull requests by where they stand, for the overview donut.
    var mineByState: [(name: String, count: Int)] {
        func state(_ pr: PullRequest) -> String {
            if pr.isDraft { return "Draft" }
            if pr.readyToMerge { return "Ready to merge" }
            if pr.checksFailed { return "Checks failing" }
            if pr.reviewDecision == "CHANGES_REQUESTED" { return "Changes requested" }
            if pr.reviewDecision == "APPROVED" { return "Approved" }
            return "Waiting for review"
        }
        let order = ["Ready to merge", "Approved", "Waiting for review", "Changes requested", "Checks failing", "Draft"]
        let counts = Dictionary(grouping: shownMine, by: state).mapValues(\.count)
        return order.compactMap { name in counts[name].map { (name, $0) } }
    }

    /// Review requests by how long since they last changed: under a day,
    /// 1–3 days, 3–7 days, over a week.
    var reviewAges: [Double] {
        var buckets = [0.0, 0, 0, 0]
        for pr in shownReview {
            let days = Date().timeIntervalSince(pr.updatedAt) / 86400
            buckets[days < 1 ? 0 : days < 3 ? 1 : days < 7 ? 2 : 3] += 1
        }
        return buckets
    }

    var widget: ViewContent {
        VStack(spacing: Space.s) {
            HStack(spacing: Space.s) {
                StatTile("To review", value: "\(shownReview.count)", theme: theme, emphasized: !shownReview.isEmpty)
                StatTile("Mine", value: "\(shownMine.count)")
                if failingMine > 0 {
                    StatTile("Failing", value: "\(failingMine)", theme: .critical, emphasized: true)
                } else {
                    StatTile("Ready", value: "\(shownMine.filter(\.readyToMerge).count)", theme: .success, emphasized: shownMine.contains(where: \.readyToMerge))
                }
            }
            if let pr = shownReview.first {
                VStack(spacing: 0) {
                    Text(pr.title).typography(.headline)
                    Text("\(pr.repo.split(separator: "/").last.map(String.init) ?? pr.repo)\(pr.author.map { " · by \($0.login)" } ?? "") · \(Self.ago(pr.updatedAt))").role(.secondary).typography(.caption)
                }
            }
        }
        .frame(fillWidth: true, fillHeight: true)
    }

    var tabs: [Tab] { showInbox ? Tab.allCases : [.review, .mine, .issues] }

    var currentTab: Tab {
        let chosen = Tab(rawValue: tab) ?? .review
        return tabs.contains(chosen) ? chosen : .review
    }

    /// The tab's title, with its count when there is something in it.
    func label(_ tab: Tab) -> String {
        let count: Int
        switch tab {
        case .review: count = shownReview.count
        case .mine: count = shownMine.count
        case .issues: count = shownIssues.count
        case .inbox: count = inbox.filter(\.unread).count
        }
        return count > 0 ? "\(tab.title) \(count)" : tab.title
    }

    @ViewBuilder func list(_ prs: [PullRequest], showAuthor: Bool, empty: (String, String)) -> ViewContent {
        if prs.isEmpty {
            if lastError == nil { EmptyState(empty.0, symbol: "checkmark", message: empty.1, theme: .success) }
        } else {
            List(prs, searchable: true) { pr in rowWithChecks(pr, showAuthor: showAuthor) }
        }
    }

    // MARK: Commands

    var searchResults: [PullRequest] = []
    var searchError: String?
    /// The text `searchResults` answers, so the same text isn't asked twice.
    var searchedText: String?

    var commands: [Command] {
        Command("search", title: "Search Pull Requests", subtitle: "Yours and to review; type to search GitHub", symbol: "magnifyingglass", keywords: ["github", "pr", "pull request"])
            .view(search: { invocation in
                try await self.search(invocation.text)
            }) { invocation in
                self.searchView(invocation.text)
            }
        Command("review-queue", title: "Review Queue", subtitle: "Pull requests waiting on your review", symbol: "arrow.triangle.pull", keywords: ["github", "pr"])
            .view { _ in
                if self.shownReview.isEmpty {
                    ContentUnavailableView("Nothing to review", symbol: "checkmark.circle", message: self.lastError ?? "You're all caught up.")
                } else {
                    List(searchable: true) {
                        ForEach(self.shownReview) { pr in self.row(pr, showAuthor: true, palette: true) }
                    }
                }
            }
        Command("open-next-review", title: "Open Next Review", symbol: "arrow.up.forward.square", keywords: ["github", "pr"]) { _ in
            guard let pr = self.shownReview.first else { return .message("Nothing to review") }
            self.markSeen(pr)
            return .open(url: pr.url, app: nil)
        }
        Command("repos", title: "Search GitHub Repositories", symbol: "book.closed", keywords: ["github", "repo", "repository", "gh"])
            .view(search: { invocation in
                await self.loadRepos()
                await self.searchRepos(invocation.text)
            }) { _ in
                if let problem = self.reposError, self.repos.isEmpty {
                    ContentUnavailableView("Can't reach GitHub", symbol: "exclamationmark.triangle", message: problem)
                } else {
                    List(searchable: true) {
                        ForEach(self.orderedRepos) { repo in self.repoRow(repo) }
                        ForEach(self.repoResults.filter { result in !self.repos.contains { $0.id == result.id } }) { repo in self.repoRow(repo) }
                        if let problem = self.repoSearchError {
                            Row("Couldn't search GitHub", subtitle: problem, symbol: "exclamationmark.triangle", key: "repo-search-error")
                        }
                    }
                }
            }
        Command("issues", title: "My GitHub Issues", subtitle: "Open issues assigned to you", symbol: "smallcircle.filled.circle", keywords: ["github", "issue", "assigned", "gh"])
            .view(search: { _ in await self.loadIssues(maxAge: 30) }) { _ in
                if let problem = self.issuesError {
                    ContentUnavailableView("Can't reach GitHub", symbol: "exclamationmark.triangle", message: problem)
                } else if self.shownIssues.isEmpty {
                    ContentUnavailableView("Nothing assigned to you", symbol: "checkmark.circle")
                } else {
                    List(self.shownIssues, searchable: true) { issue in self.issueRow(issue) }
                }
            }
        Command("inbox", title: "GitHub Inbox", subtitle: "Mentions, review requests and everything GitHub notifies you about", symbol: "tray", keywords: ["github", "notifications", "mentions", "inbox", "gh"])
            .view(search: { _ in await self.loadInbox(maxAge: 30) }) { _ in
                if let inboxError = self.inboxError, self.inbox.isEmpty {
                    ContentUnavailableView("Can't read your GitHub inbox", symbol: "exclamationmark.triangle", message: inboxError)
                } else if self.inbox.isEmpty {
                    ContentUnavailableView("Inbox zero", symbol: "tray")
                } else {
                    List(searchable: true) {
                        ForEach(self.inbox) { item in self.inboxRow(item) }
                        Row("Mark All as Read", symbol: "checkmark.circle", key: "inbox-mark-all")
                            .action("Mark All as Read") { await self.markAllRead() }
                    }
                }
            }
        Command("create-issue", title: "Create GitHub Issue", symbol: "plus.circle", keywords: ["github", "issue", "new", "bug", "gh"])
            .argument("repo", placeholder: "Repository", required: false)
            .stackbarOnly()
            .view(search: { _ in await self.loadRepos() }) { invocation in self.issueForm(repo: invocation["repo"]) }
        // "owner/repo" or "repo#123" typed at the palette's root: a saved
        // repository, or one of the pull requests already fetched. Nothing
        // is fetched per keystroke.
        Command("jump", title: "Jump to a Repository or Pull Request", symbol: "arrow.triangle.pull", keywords: ["github"])
            .view(search: { _ in }) { invocation in
                List {
                    ForEach(self.rootPulls(invocation.text)) { pr in self.row(pr, showAuthor: true, palette: true) }
                    ForEach(self.rootRepos(invocation.text)) { repo in self.repoRow(repo) }
                }
            }
            .rootSearch(section: "GitHub", matching: #"[\w.-]+/[\w.-]*|[\w./-]*#\d+"#)
            .stackbarOnly()
        // A pull request's checks and deployments, opened from a row with ⌘I.
        Command("checks", title: "Pull Request Checks", symbol: "checklist", keywords: ["github", "ci", "checks"])
            .argument("url", placeholder: "Pull request URL")
            .stackbarOnly()
            .view(search: { invocation in
                if let url = invocation["url"] { await self.loadDetails(url, maxAge: 15) }
            }) { invocation in
                self.checksView(invocation["url"] ?? "")
            }
        Command("refresh", title: "Refresh Pull Requests", symbol: "arrow.clockwise", keywords: ["github"]) { _ in
            try await self.refresh()
            return .message(self.lastError ?? "\(self.shownReview.count) to review, \(self.shownMine.count) of yours open")
        }
    }

    /// Searches GitHub for pull requests that involve you. Two characters
    /// or fewer show the lists already fetched instead.
    func search(_ text: String) async throws {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard text.count > 2 else {
            searchResults = []
            searchError = nil
            searchedText = nil
            return
        }
        // The host sends the newest text once this returns, so a short wait
        // folds a burst of keystrokes into one request; the same text again
        // (a reopen, a refresh) keeps its results.
        if text == searchedText, searchError == nil { return }
        try? await Task.sleep(for: .milliseconds(250))
        searchedText = text
        guard try await loadEnterpriseServer() else {
            searchError = "Enter your GitHub Enterprise server as GITHUB_ENTERPRISE_URL."
            return
        }
        guard let token = try await Stackbar.secret("GITHUB_TOKEN"), !token.isEmpty else {
            searchError = "Add a GitHub token to search."
            return
        }
        noteCredentials(token)
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let query = "query { found: search(query: \"is:pr archived:false involves:@me \(escaped)\", type: ISSUE, first: 30) { nodes { ...pr } } } \(Self.fragment)"
        do {
            let response = try await Stackbar.http(HTTPRequest(url: graphqlURL, method: "POST", headers: [
                "Authorization": "Bearer \(token)", "Content-Type": "application/json", "Accept": "application/json",
            ], body: try JSONEncoder().encode(["query": query]), timeout: Self.refreshTimeout))
            guard (200..<300).contains(response.status) else {
                throw HostError(response.status == 401 ? "GitHub rejected the token (401); set a new GITHUB_TOKEN" : "GitHub answered \(response.status)")
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let reply = try decoder.decode(SearchReply.self, from: response.body)
            guard let data = reply.data else { throw HostError(reply.errors?.map(\.message).joined(separator: "; ") ?? "GitHub sent no data") }
            searchResults = data.found.nodes
            searchError = nil
        } catch {
            searchResults = []
            searchError = "\(error)"
        }
    }

    @ViewBuilder func searchView(_ text: String) -> ViewContent {
        if text.trimmingCharacters(in: .whitespaces).count <= 2 {
            // The host filters these as you type.
            List(searchable: true) {
                Section("Waiting on your review") {
                    ForEach(shownReview) { pr in row(pr, showAuthor: true, palette: true) }
                }
                Section("Yours") {
                    ForEach(shownMine) { pr in row(pr, showAuthor: false, palette: true) }
                }
            }
        } else if let searchError {
            ContentUnavailableView("Search failed", symbol: "exclamationmark.triangle", message: searchError)
        } else if searchResults.isEmpty {
            ContentUnavailableView("No pull requests", symbol: "magnifyingglass", message: "Nothing that involves you matches \"\(text)\".")
        } else {
            List {
                ForEach(searchResults) { pr in row(pr, showAuthor: true, palette: true) }
            }
        }
    }

    // MARK: Agents

    var tools: [AgentTool] {
        AgentTool("review_queue", description: "Pull requests waiting on my review, one per line") { _ in
            if !self.loaded { try await self.refresh() }
            if self.toReview.isEmpty && self.mine.isEmpty, let problem = self.lastError { return problem }
            return self.toReview.isEmpty ? "No pull requests are waiting on your review." : self.toReview.map { "\($0.id) \($0.title) by \($0.author?.login ?? "?") (\($0.url))" }.joined(separator: "\n")
        }
        AgentTool("my_issues", description: "Open GitHub issues assigned to me, one per line") { _ in
            if !self.loaded { try await self.refresh() }
            if self.issues.isEmpty, !self.issuesLoaded, let problem = self.issuesError ?? self.lastError { return problem }
            return self.issues.isEmpty ? "No open issues are assigned to you." : self.issues.map { "\($0.reference) \($0.title) (\($0.html_url))" }.joined(separator: "\n")
        }
        AgentTool("my_pull_requests", description: "My open pull requests with their checks and review state, one per line") { _ in
            if !self.loaded { try await self.refresh() }
            if self.toReview.isEmpty && self.mine.isEmpty, let problem = self.lastError { return problem }
            return self.mine.isEmpty ? "You have no open pull requests." : self.mine.map { pr in
                "\(pr.id) \(pr.title): checks \(pr.checks?.lowercased() ?? "none"), review \(pr.reviewDecision?.lowercased().replacingOccurrences(of: "_", with: " ") ?? "none")\(pr.mergeable == "CONFLICTING" ? ", has conflicts" : "") (\(pr.url))"
            }.joined(separator: "\n")
        }
    }
}

// MARK: - Checks and deployments

/// One check on a pull request's latest commit: a GitHub Actions job or
/// another app's check run, or a commit status.
struct CheckItem: Equatable, Identifiable {
    enum State: Int, Comparable {
        case failed, cancelled, running, queued, passed, neutral, skipped
        static func < (a: State, b: State) -> Bool { a.rawValue < b.rawValue }
    }
    let id: String
    let name: String
    /// The workflow (or app) it belongs to: "CI".
    let group: String?
    let state: State
    let isRequired: Bool
    let url: String?
    let startedAt: Date?
    let completedAt: Date?
    /// The first step that failed: "Run swift test".
    let failedStep: String?
    /// The first errors it reported, "path:line message".
    let annotations: [String]
    /// The Actions workflow run, which Re-run restarts.
    let runID: Int?
    /// A commit status's description.
    let note: String?

    var title: String { group.map { "\($0) / \(name)" } ?? name }
}

/// A deployment of the pull request's latest commit.
struct DeployItem: Equatable, Identifiable {
    let id: String
    let environment: String
    /// SUCCESS, ACTIVE, IN_PROGRESS, QUEUED, PENDING, FAILURE, ERROR, INACTIVE.
    let state: String
    let url: String?
    let logURL: String?
    let createdAt: Date
}

/// What a pull request's checks and deployments look like now.
struct PRDetails: Equatable {
    var checks: [CheckItem]
    var deployments: [DeployItem]
    var fetchedAt: Date

    var failed: [CheckItem] { checks.filter { $0.state == .failed } }
    var isRunning: Bool { checks.contains { $0.state == .running || $0.state == .queued } || deployments.contains { ["IN_PROGRESS", "QUEUED", "PENDING"].contains($0.state) } }

    /// "2 failed · 1 running · 14 passed".
    var summary: String {
        let count = { (state: CheckItem.State) in self.checks.filter { $0.state == state }.count }
        let parts: [(Int, String)] = [(count(.failed), "failed"), (count(.cancelled), "cancelled"), (count(.running), "running"),
                                      (count(.queued), "queued"), (count(.passed), "passed"), (count(.skipped) + count(.neutral), "skipped")]
        let text = parts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
        return text.isEmpty ? "No checks" : text
    }
}

/// The reply for several pull requests' checks, one alias (`p0`, `p1`…)
/// each; an alias GitHub couldn't answer comes back null.
struct BatchDetailsReply: Decodable {
    let data: [String: DetailsReply.Repository?]?
}

/// The GraphQL reply for one pull request's checks and deployments.
struct DetailsReply: Decodable {
    struct Problem: Decodable { let message: String }
    struct Payload: Decodable { let repository: Repository? }
    struct Repository: Decodable { let pullRequest: PullRequest? }
    struct PullRequest: Decodable { let commits: Commits }
    struct Commits: Decodable { let nodes: [Node] }
    struct Node: Decodable { let commit: Commit }
    struct Commit: Decodable {
        let oid: String
        let statusCheckRollup: Rollup?
        let deployments: Deployments?
    }
    struct Rollup: Decodable { let contexts: Contexts }
    struct Contexts: Decodable { let nodes: [Context?] }
    struct Context: Decodable {
        let __typename: String
        let isRequired: Bool?
        // CheckRun
        let databaseId: Int?
        let name: String?
        let status: String?
        let conclusion: String?
        let detailsUrl: String?
        let startedAt: Date?
        let completedAt: Date?
        let checkSuite: Suite?
        let steps: Steps?
        let annotations: Annotations?
        // StatusContext
        let context: String?
        let state: String?
        let targetUrl: String?
        let description: String?
        let createdAt: Date?
    }
    struct Suite: Decodable { let workflowRun: Run?; let app: App? }
    struct Run: Decodable { let databaseId: Int?; let workflow: Workflow? }
    struct Workflow: Decodable { let name: String }
    struct App: Decodable { let name: String }
    struct Steps: Decodable { let nodes: [Step?] }
    struct Step: Decodable { let name: String; let conclusion: String? }
    struct Annotations: Decodable { let nodes: [Annotation?] }
    struct Annotation: Decodable { let message: String; let path: String?; let location: Location? }
    struct Location: Decodable { let start: Position }
    struct Position: Decodable { let line: Int }
    struct Deployments: Decodable { let nodes: [Deployment?] }
    struct Deployment: Decodable {
        let id: String
        let environment: String?
        let state: String?
        let createdAt: Date
        let latestStatus: Status?
    }
    struct Status: Decodable { let state: String; let environmentUrl: String?; let logUrl: String? }

    let data: Payload?
    let errors: [Problem]?

    /// The commit's checks and deployments for one pull request; `number`
    /// is `$number` in the one-pull query or a literal in a batch.
    static func selection(number: String) -> String {
        """
        commits(last: 1) { nodes { commit { oid \
        statusCheckRollup { contexts(first: 100) { nodes { __typename \
        ... on CheckRun { databaseId name status conclusion detailsUrl startedAt completedAt isRequired(pullRequestNumber: \(number)) \
        checkSuite { workflowRun { databaseId workflow { name } } app { name } } \
        steps(first: 60) { nodes { name conclusion } } \
        annotations(first: 5) { nodes { message path location { start { line } } } } } \
        ... on StatusContext { context state targetUrl description createdAt isRequired(pullRequestNumber: \(number)) } } } } \
        deployments(first: 5, orderBy: { field: CREATED_AT, direction: DESC }) { nodes { id environment state createdAt latestStatus { state environmentUrl logUrl } } } \
        } } }
        """
    }

    static let query = "query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) { pullRequest(number: $number) { \(selection(number: "$number")) } } }"

    /// The checks and deployments, newest deployment per environment.
    func details(at now: Date = Date()) -> PRDetails? {
        data?.repository?.pullRequest.flatMap { Self.details($0, at: now) }
    }

    static func details(_ pull: PullRequest, at now: Date = Date()) -> PRDetails? {
        guard let commit = pull.commits.nodes.last?.commit else { return nil }
        let checks = (commit.statusCheckRollup?.contexts.nodes ?? []).compactMap { $0 }.enumerated().compactMap { index, context -> CheckItem? in
            if context.__typename == "StatusContext" {
                let state: CheckItem.State = switch context.state {
                case "SUCCESS": .passed
                case "FAILURE", "ERROR": .failed
                default: .running
                }
                return CheckItem(id: "status-\(index)-\(context.context ?? "")", name: context.context ?? "Status", group: nil, state: state,
                                 isRequired: context.isRequired ?? false, url: context.targetUrl, startedAt: context.createdAt, completedAt: nil,
                                 failedStep: nil, annotations: [], runID: nil, note: context.description)
            }
            guard context.__typename == "CheckRun", let name = context.name else { return nil }
            let state: CheckItem.State
            if context.status != "COMPLETED" {
                state = context.status == "IN_PROGRESS" ? .running : .queued
            } else {
                state = switch context.conclusion {
                case "SUCCESS": .passed
                case "FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED": .failed
                case "CANCELLED": .cancelled
                case "SKIPPED": .skipped
                default: .neutral
                }
            }
            let failedStep = (context.steps?.nodes ?? []).compactMap { $0 }.first { ["FAILURE", "TIMED_OUT", "CANCELLED"].contains($0.conclusion ?? "") }?.name
            let annotations = (context.annotations?.nodes ?? []).compactMap { $0 }.map { note -> String in
                let place = note.path.map { path in note.location.map { "\(path):\($0.start.line)" } ?? path }
                let message = note.message.split(separator: "\n").first.map(String.init) ?? note.message
                return [place, message].compactMap { $0 }.joined(separator: " ")
            }
            let group = context.checkSuite?.workflowRun?.workflow?.name ?? context.checkSuite?.app.map(\.name).flatMap { $0 == "GitHub Actions" ? nil : $0 }
            return CheckItem(id: "run-\(context.databaseId ?? index)", name: name, group: group, state: state, isRequired: context.isRequired ?? false,
                             url: context.detailsUrl, startedAt: context.startedAt, completedAt: context.completedAt, failedStep: failedStep,
                             annotations: annotations, runID: context.checkSuite?.workflowRun?.databaseId, note: nil)
        }
        var seen: Set<String> = []
        let deployments = (commit.deployments?.nodes ?? []).compactMap { $0 }.compactMap { deployment -> DeployItem? in
            let environment = deployment.environment ?? "Deployment"
            guard seen.insert(environment).inserted else { return nil }
            return DeployItem(id: deployment.id, environment: environment, state: deployment.latestStatus?.state ?? deployment.state ?? "PENDING",
                              url: deployment.latestStatus?.environmentUrl.flatMap { $0.isEmpty ? nil : $0 },
                              logURL: deployment.latestStatus?.logUrl.flatMap { $0.isEmpty ? nil : $0 }, createdAt: deployment.createdAt)
        }
        let sorted = checks.sorted { ($0.state.rawValue, $0.isRequired ? 0 : 1, $0.title.lowercased()) < ($1.state.rawValue, $1.isRequired ? 0 : 1, $1.title.lowercased()) }
        return PRDetails(checks: sorted, deployments: deployments, fetchedAt: now)
    }
}

extension PRCockpit {
    /// owner, name and number from a pull request's web URL, on github.com
    /// or an Enterprise server: `…/owner/name/pull/123`.
    static func parts(of url: String) -> (owner: String, name: String, number: Int)? {
        let path = URL(string: url)?.pathComponents.filter { $0 != "/" } ?? []
        guard path.count >= 4, path[path.count - 2] == "pull", let number = Int(path[path.count - 1]) else { return nil }
        return (path[path.count - 4], path[path.count - 3], number)
    }

    func pull(_ url: String) -> PullRequest? {
        (toReview + mine + searchResults + recentlyClosed).first { $0.url == url }
    }

    /// Fetches a pull request's checks and deployments, unless what is
    /// kept is younger than `maxAge` seconds.
    func loadDetails(_ url: String, maxAge: Double = 0) async {
        if let kept = details[url], Date().timeIntervalSince(kept.fetchedAt) < maxAge { return }
        guard let parts = Self.parts(of: url) else { detailErrors[url] = "That isn't a pull request link."; return }
        do {
            guard try await loadEnterpriseServer() else { throw HostError("Enter your GitHub Enterprise server as GITHUB_ENTERPRISE_URL.") }
            guard let token = try await Stackbar.secret("GITHUB_TOKEN"), !token.isEmpty else { throw HostError("Add a GitHub token to see checks.") }
            noteCredentials(token)
            struct Body: Encodable {
                struct Variables: Encodable { let owner: String; let name: String; let number: Int }
                let query: String
                let variables: Variables
            }
            let body = try JSONEncoder().encode(Body(query: DetailsReply.query, variables: .init(owner: parts.owner, name: parts.name, number: parts.number)))
            let response = try await Stackbar.http(HTTPRequest(url: graphqlURL, method: "POST", headers: [
                "Authorization": "Bearer \(token)", "Content-Type": "application/json", "Accept": "application/json",
            ], body: body, timeout: Self.refreshTimeout))
            guard (200..<300).contains(response.status) else {
                throw HostError(response.status == 401 ? "GitHub rejected the token (401); set a new GITHUB_TOKEN" : "GitHub answered \(response.status)")
            }
            let reply = try Self.restDecoder.decode(DetailsReply.self, from: response.body)
            guard let found = reply.details() else {
                throw HostError(reply.errors?.map(\.message).joined(separator: "; ") ?? "GitHub has no checks for this pull request")
            }
            if details.count > 40, let oldest = details.min(by: { $0.value.fetchedAt < $1.value.fetchedAt })?.key { details[oldest] = nil }
            details[url] = found
            detailErrors[url] = nil
            if let pr = pull(url) { checksStamp[url] = Self.stamp(pr) }
        } catch {
            detailErrors[url] = "\(error)"
        }
    }

    /// When a pull request's checks were last seen to change: GitHub moves
    /// `updatedAt` on a push and the rollup state when a check finishes.
    static func stamp(_ pr: PullRequest) -> String {
        "\(pr.updatedAt.timeIntervalSince1970)|\(pr.checks ?? "")"
    }

    /// The listed pull requests whose checks aren't kept or changed since,
    /// at most ten, fetched together so the palette can preview them.
    func prefetchChecks() async {
        var seen: Set<String> = []
        let stale = (shownReview + shownMine).prefix(20).filter { pr in
            guard seen.insert(pr.url).inserted else { return false }
            return details[pr.url] == nil || checksStamp[pr.url] != Self.stamp(pr)
        }
        guard !stale.isEmpty else { return }
        await loadDetails(Array(stale.prefix(10)))
    }

    /// Several pull requests' checks and deployments in one GraphQL request,
    /// one alias each. It runs in the background, so a failure is left for
    /// the panel and the checks view, which ask again and say why.
    func loadDetails(_ pulls: [PullRequest]) async {
        let named = { (text: String) in !text.isEmpty && text.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) } }
        let targets = pulls.compactMap { pr in Self.parts(of: pr.url).map { (pr: pr, parts: $0) } }.filter { named($0.parts.owner) && named($0.parts.name) }
        guard !targets.isEmpty else { return }
        do {
            guard try await loadEnterpriseServer(), let token = try await Stackbar.secret("GITHUB_TOKEN"), !token.isEmpty else { return }
            let fields = targets.enumerated().map { index, target in
                "p\(index): repository(owner: \"\(target.parts.owner)\", name: \"\(target.parts.name)\") { pullRequest(number: \(target.parts.number)) { \(DetailsReply.selection(number: "\(target.parts.number)")) } }"
            }
            let body = try JSONEncoder().encode(["query": "query { \(fields.joined(separator: " ")) }"])
            let response = try await Stackbar.http(HTTPRequest(url: graphqlURL, method: "POST", headers: [
                "Authorization": "Bearer \(token)", "Content-Type": "application/json", "Accept": "application/json",
            ], body: body, timeout: Self.refreshTimeout))
            guard (200..<300).contains(response.status) else { return }
            let reply = try Self.restDecoder.decode(BatchDetailsReply.self, from: response.body)
            let now = Date()
            for (index, target) in targets.enumerated() {
                guard let pull = reply.data?["p\(index)"]??.pullRequest, let found = DetailsReply.details(pull, at: now) else { continue }
                details[target.pr.url] = found
                detailErrors[target.pr.url] = nil
                checksStamp[target.pr.url] = Self.stamp(target.pr)
            }
            while details.count > 40, let oldest = details.min(by: { $0.value.fetchedAt < $1.value.fetchedAt })?.key {
                details[oldest] = nil
                checksStamp[oldest] = nil
            }
        } catch {}
    }

    func toggleChecks(_ pr: PullRequest) async {
        if expanded == pr.url {
            expanded = nil
            return
        }
        expanded = pr.url
        expandedAt = Date()
        markSeen(pr)
        await loadDetails(pr.url, maxAge: 15)
    }

    /// While the open pull request's checks run, fetches them again: every
    /// 20 seconds, for 10 minutes after it was opened.
    func followOpenChecks() async {
        guard let url = expanded, let expandedAt, Date().timeIntervalSince(expandedAt) < 600 else { return }
        let rollupMoved = pull(url).map { pr in
            guard let kept = details[url] else { return true }
            return (pr.checks == "PENDING" || pr.checks == "EXPECTED") != kept.isRunning
        } ?? false
        guard details[url]?.isRunning == true || rollupMoved else { return }
        await loadDetails(url, maxAge: 15)
    }

    /// Re-runs a workflow run's failed jobs (or all of them). The first
    /// press only asks for a second one within 10 seconds.
    func rerun(_ url: String, runID: Int, failedOnly: Bool) async {
        guard let parts = Self.parts(of: url) else { return }
        let key = "\(runID)-\(failedOnly)"
        guard rerunArmed == key, Date().timeIntervalSince(rerunArmedAt) < 10 else {
            rerunArmed = key
            rerunArmedAt = Date()
            Stackbar.hud("Press again within 10 s to re-run \(failedOnly ? "the failed jobs" : "every job")")
            return
        }
        rerunArmed = nil
        do {
            _ = try await rest("/repos/\(parts.owner)/\(parts.name)/actions/runs/\(runID)/\(failedOnly ? "rerun-failed-jobs" : "rerun")", method: "POST", body: Data("{}".utf8), timeout: Self.refreshTimeout)
            Stackbar.hud(failedOnly ? "Re-running the failed jobs" : "Re-running every job")
            expanded = url
            expandedAt = Date()
            try? await Task.sleep(for: .seconds(2))
            await loadDetails(url)
        } catch {
            let text = "\(error)"
            Stackbar.hud(text.contains("403") || text.contains("404") ? "Re-running needs a token with Actions write access" : text, isError: true)
        }
    }

    /// The failures in words, to paste into a chat or an issue.
    func checksText(_ pr: PullRequest?, _ found: PRDetails) -> String {
        var lines: [String] = []
        if let pr { lines.append("\(pr.title) (\(pr.id)): \(found.summary)") } else { lines.append(found.summary) }
        for check in found.checks where check.state == .failed || check.state == .cancelled {
            lines.append("✕ \(check.title)\(check.failedStep.map { ": \($0)" } ?? "")\(check.url.map { " \($0)" } ?? "")")
            lines += check.annotations.map { "    \($0)" }
            if let note = check.note { lines.append("    \(note)") }
        }
        for deployment in found.deployments {
            lines.append("\(deployment.environment): \(Self.deployWord(deployment.state))\(deployment.url.map { " \($0)" } ?? "")")
        }
        return lines.joined(separator: "\n")
    }

    static func symbol(_ state: CheckItem.State) -> String {
        switch state {
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "slash.circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .queued: return "clock"
        case .passed: return "checkmark.circle.fill"
        case .neutral, .skipped: return "minus.circle"
        }
    }

    static func word(_ state: CheckItem.State) -> (String, Role) {
        switch state {
        case .failed: return ("Failed", .critical)
        case .cancelled: return ("Cancelled", .secondary)
        case .running: return ("Running", .warning)
        case .queued: return ("Queued", .secondary)
        case .passed: return ("Passed", .success)
        case .neutral: return ("Neutral", .secondary)
        case .skipped: return ("Skipped", .secondary)
        }
    }

    static func deployWord(_ state: String) -> String {
        switch state {
        case "SUCCESS", "ACTIVE": return "deployed"
        case "IN_PROGRESS": return "deploying"
        case "QUEUED", "PENDING", "WAITING": return "waiting"
        case "FAILURE", "ERROR": return "failed"
        case "INACTIVE", "DESTROYED": return "replaced"
        default: return state.lowercased()
        }
    }

    /// "3m 12s", or how long it has been running.
    static func duration(_ check: CheckItem, now: Date = Date()) -> String? {
        guard let start = check.startedAt else { return nil }
        let seconds = Int((check.completedAt ?? now).timeIntervalSince(start))
        guard seconds >= 0 else { return nil }
        let text = seconds < 60 ? "\(seconds)s" : seconds < 3600 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds / 3600)h \(seconds / 60 % 60)m"
        return check.completedAt == nil ? "running \(text)" : text
    }

    func checkRow(_ check: CheckItem, in url: String) -> Row {
        let detail = [check.failedStep, check.annotations.first, check.note, Self.duration(check)].compactMap { $0 }.joined(separator: " · ")
        var row = Row(check.title, subtitle: detail.isEmpty ? nil : detail, symbol: Self.symbol(check.state), key: "check-\(url)-\(check.id)")
        let word = Self.word(check.state)
        row = row.badge(word.0, role: word.1)
        if check.isRequired { row = row.badge("Required", role: check.state == .failed ? .critical : .secondary) }
        if let link = check.url { row = row.action("Open log") { Stackbar.open(link) } }
        if let runID = check.runID, check.state == .failed || check.state == .cancelled {
            row = row.action("Re-run failed jobs") { await self.rerun(url, runID: runID, failedOnly: true) }
        }
        if let runID = check.runID, check.state == .failed || check.state == .cancelled {
            row = row.action("Re-run all jobs") { await self.rerun(url, runID: runID, failedOnly: false) }
        }
        if !check.annotations.isEmpty {
            row = row.preview(text: check.annotations.joined(separator: "\n"), caption: check.failedStep)
                .action("Copy errors") { Stackbar.copy(check.annotations.joined(separator: "\n")) }
        }
        return row.hiddenFromPalette()
    }

    func deployRow(_ deployment: DeployItem, in url: String) -> Row {
        let failed = ["FAILURE", "ERROR"].contains(deployment.state)
        let done = ["SUCCESS", "ACTIVE"].contains(deployment.state)
        var row = Row(deployment.environment, subtitle: [deployment.url, Self.ago(deployment.createdAt) + " ago"].compactMap { $0 }.joined(separator: " · "),
                      symbol: "shippingbox", key: "deploy-\(url)-\(deployment.id)")
            .badge(Self.deployWord(deployment.state).capitalized, role: failed ? .critical : done ? .success : .warning)
        if let site = deployment.url { row = row.action("Open \(deployment.environment)") { Stackbar.open(site) }.action("Copy link") { Stackbar.copy(site) } }
        if let log = deployment.logURL { row = row.action("Open deployment log") { Stackbar.open(log) } }
        return row.hiddenFromPalette()
    }

    func summaryRow(_ found: PRDetails, url: String) -> Row {
        let failedRuns = Array(Set(found.checks.filter { $0.state == .failed }.compactMap(\.runID))).sorted()
        var summary = Row(found.summary, subtitle: found.deployments.isEmpty ? "Checks" : "Checks and deployments", symbol: found.failed.isEmpty ? (found.isRunning ? "hourglass" : "checkmark.seal") : "exclamationmark.triangle.fill", key: "checks-\(url)")
            .action("Open checks page") { Stackbar.open(url + "/checks") }
        if failedRuns.count == 1, let run = failedRuns.first {
            summary = summary.action("Re-run failed jobs") { await self.rerun(url, runID: run, failedOnly: true) }
        }
        summary = summary.action("Copy summary") { Stackbar.copy(self.checksText(self.pull(url), found)) }
            .action("Refresh checks") { await self.loadDetails(url) }
            .action("Hide checks") { self.expanded = nil }
        return summary.hiddenFromPalette()
    }

    /// The rows under an open pull request: a summary with the actions for
    /// all of them, then failures first, then deployments. Passing checks
    /// fold into one row when there are many.
    @ViewBuilder func checkRows(_ url: String) -> ViewContent {
        if let found = details[url] {
            summaryRow(found, url: url)
            if let problem = detailErrors[url] { Row("Couldn't refresh the checks", subtitle: problem, symbol: "exclamationmark.triangle", key: "checks-error-\(url)").hiddenFromPalette() }
            let passed = found.checks.filter { $0.state >= .passed }
            let rest = found.checks.filter { $0.state < .passed }
            ForEach(rest) { check in checkRow(check, in: url) }
            if passed.count > 4 && !showAllPassed.contains(url) {
                Row("\(passed.count) passed or skipped", symbol: "checkmark.circle", key: "passed-\(url)")
                    .action("Show them") { self.showAllPassed.insert(url) }
                    .hiddenFromPalette()
            } else {
                ForEach(passed) { check in checkRow(check, in: url) }
            }
            ForEach(found.deployments) { deployment in deployRow(deployment, in: url) }
        } else if let problem = detailErrors[url] {
            Row("Couldn't load the checks", subtitle: problem, symbol: "exclamationmark.triangle", key: "checks-error-\(url)")
                .action("Try again") { await self.loadDetails(url) }
                .hiddenFromPalette()
        } else {
            Row("Loading checks…", symbol: "hourglass", key: "checks-loading-\(url)").hiddenFromPalette()
        }
    }

    /// A pull request's row, with its checks under it while it is open.
    @ViewBuilder func rowWithChecks(_ pr: PullRequest, showAuthor: Bool) -> ViewContent {
        row(pr, showAuthor: showAuthor)
        if expanded == pr.url { checkRows(pr.url) }
    }

    /// The palette's view of one pull request's checks and deployments.
    @ViewBuilder func checksView(_ url: String) -> ViewContent {
        if details[url] == nil, let problem = detailErrors[url] {
            ContentUnavailableView("Can't load the checks", symbol: "exclamationmark.triangle", message: problem)
        } else if let found = details[url] {
            List(searchable: true) {
                Section(pull(url).map { "\($0.title) · \($0.id)" } ?? (Self.parts(of: url).map { "\($0.owner)/\($0.name)#\($0.number)" } ?? "Checks")) {
                    checkRows(url)
                }
                if found.checks.isEmpty && found.deployments.isEmpty {
                    Row("This pull request has no checks", symbol: "checkmark.circle", key: "no-checks").action("Open in browser") { Stackbar.open(url) }
                }
            }
        } else {
            ContentUnavailableView("Loading checks…", symbol: "hourglass")
        }
    }
}
