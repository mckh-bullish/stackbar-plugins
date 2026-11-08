import StackbarKit
import Foundation

/// Which of your local git repositories are behind their remote, ahead of
/// it, diverged or holding uncommitted changes, with the safe ones updated in
/// one click.
///
/// You choose the folders your code lives in (Stackbar asks with an Open
/// panel, and `git` may then run only there). It finds the repositories in
/// them, groups linked worktrees under their repository, and checks each with
/// `git status --porcelain=v2 --branch`, which reads only local state. Fetches
/// run on their own every so often, a few repositories per minute, and never
/// touch your working tree. Pulls are fast-forward only unless you choose
/// rebase, a repository with uncommitted changes is skipped unless you choose
/// otherwise, and nothing is ever force-pushed.
@main
final class GitSync: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.git-sync",
        name: "Git Sync",
        version: "1.1.0",
        summary: "Which local repositories are behind or ahead of their remote, with the safe ones updated in one click.",
        surfaces: [.menuBar, .panel, .window, .widget, .settings],
        triggers: [.launch, .every(.seconds(60)), .wake],
        capabilities: [.run(commands: ["git", "find"]), .sshAgent, .openURLs(schemes: ["*"])],
        minimumStackbar: "0.35.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Developer/GitSync",
        accent: .green,
        symbol: "arrow.triangle.branch"
    )

    // MARK: Model

    /// One working tree: the repository's main checkout or a linked worktree.
    struct Worktree: Equatable, Identifiable, Codable {
        var path: String
        var branch: String?
        var upstream: String?
        var ahead = 0
        var behind = 0
        /// Changed tracked files; nil when the worktree is outside the
        /// folders you chose, so it can't be checked.
        var changes: Int?
        var conflicts = 0
        var isMain = false
        var locked = false
        /// Its folder is gone (`git worktree prune` cleans it up).
        var missing = false
        /// The upstream branch was deleted on the remote.
        var upstreamGone = false
        /// Its branch is merged into the default branch.
        var merged = false
        /// When its branch tip was committed.
        var lastCommit: Date?
        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
        var isDirty: Bool { (changes ?? 0) > 0 || conflicts > 0 }
        var madeByAgent: Bool { GitSync.agentMarkers.contains { path.contains($0) } }
        /// A branch that was pushed and is merged, or whose remote branch was
        /// deleted (as after a merged pull request). A branch never pushed
        /// counts as neither, so a worktree just made is never offered.
        var removable: Bool { !isMain && !locked && !missing && changes == 0 && conflicts == 0 && (upstreamGone || (merged && upstream != nil)) && ahead == 0 }
    }

    /// One local branch, for the window's all-branches view.
    struct Branch: Equatable, Identifiable, Codable {
        var name: String
        var upstream: String?
        var ahead = 0
        var behind = 0
        var gone = false
        var merged = false
        var id: String { name }
    }

    struct Repository: Equatable, Identifiable, Codable {
        /// The main checkout's folder (or the first worktree found, for a
        /// repository whose main checkout is elsewhere).
        var path: String
        /// The shared `.git` folder, which identifies the repository.
        var commonDir: String
        var worktrees: [Worktree] = []
        var branches: [Branch] = []
        var remoteURL: String?
        var defaultBranch: String?
        var problem: String?
        var id: String { commonDir }
        var name: String { (path as NSString).lastPathComponent }
        var main: Worktree? { worktrees.first { $0.isMain } ?? worktrees.first }
        var linked: [Worktree] { worktrees.filter { !$0.isMain } }
    }

    enum State: Int, CaseIterable, Comparable {
        case conflicts, diverged, behind, ahead, dirty, noUpstream, upToDate, problem
        static func < (a: State, b: State) -> Bool { a.rawValue < b.rawValue }
        var title: String {
            switch self {
            case .conflicts: return "Conflicts"
            case .diverged: return "Diverged"
            case .behind: return "Behind"
            case .ahead: return "Not pushed"
            case .dirty: return "Uncommitted changes"
            case .noUpstream: return "No upstream"
            case .upToDate: return "Up to date"
            case .problem: return "Can't check"
            }
        }
    }

    static func state(of tree: Worktree?) -> State {
        guard let tree else { return .problem }
        if tree.conflicts > 0 { return .conflicts }
        if tree.ahead > 0 && tree.behind > 0 { return .diverged }
        if tree.behind > 0 { return .behind }
        if tree.ahead > 0 { return .ahead }
        if tree.isDirty { return .dirty }
        if tree.upstream == nil || tree.upstreamGone { return .noUpstream }
        return .upToDate
    }

    func state(_ repo: Repository) -> State {
        repo.problem != nil ? .problem : Self.state(of: repo.main)
    }

    /// Paths that coding agents keep their worktrees under.
    nonisolated static let agentMarkers = ["/.claude/worktrees/", "/.worktrees/", "/conductor/", "/.codex/", "/.cursor/worktrees/"]

    // MARK: State

    var repositories: [Repository] = []
    var scannedAt: Date?
    /// The folders the last scan looked in; a change scans again.
    var scannedFolders: [String] = []
    var checkedAt: Date?
    var loaded = false
    var busy: String?
    var lastResult: String?
    var problem: String?
    /// The folders Stackbar lets git run in, from `grantedFolders()`.
    var folders: [String] = []
    /// The repository whose incoming commits and worktrees are open.
    var expanded: String?
    /// Incoming commits by repository, "abc1234 message", newest first.
    var incoming: [String: [String]] = [:]

    /// How deep to look in each folder, by path; 2 when not set.
    @Stored("depths") var depths: [String: Int] = [:]
    @Stored("hidden") var hidden: [String] = []
    /// When Git Sync last fetched each repository, by its `.git` folder.
    @Stored("fetchedAt") var fetchedAt: [String: Date] = [:]
    /// Minutes between fetches; 0 fetches only when asked.
    @Stored("fetchMinutes") var fetchMinutes = 15
    /// "ff" (fast-forward only) or "rebase".
    @Stored("pullMode") var pullMode = "ff"
    /// "skip", "stash" or "ask".
    @Stored("dirtyMode") var dirtyMode = "skip"
    @Stored("allBranches") var allBranches = false
    /// "behind", "always" or "never".
    @Stored("menuBarMode") var menuBarMode = "behind"
    @Stored("countAhead") var countAhead = false
    /// Bundle ids; "" is Finder.
    @Stored("editor") var editor = ""
    @Stored("terminal") var terminal = "com.apple.Terminal"
    /// "off", "behind" or "diverged".
    @Stored("notifyMode") var notifyMode = "off"
    @Stored("showWorktrees") var showWorktrees = true
    @Stored("updateWorktrees") var updateWorktrees = true
    /// "sibling" (next to the repository), "inside" (a .worktrees folder in
    /// it) or "folder" (`worktreeFolder`).
    @Stored("worktreePlace") var worktreePlace = "sibling"
    @Stored("worktreeFolder") var worktreeFolder = ""
    /// Repositories behind at the last check, for notifications.
    @Stored("wasBehind") var wasBehind: [String] = []

    let theme = Theme.green

    // MARK: Running git

    /// Every git run: no prompts (a password prompt would hang until the
    /// timeout), SSH that gives up instead of asking, no lock on the index
    /// while you work, and no colour.
    static let gitEnvironment = [
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_SSH_COMMAND": "ssh -o BatchMode=yes -o ConnectTimeout=15",
        "GIT_OPTIONAL_LOCKS": "0",
        "LC_ALL": "C",
    ]

    struct GitFailure: Error, CustomStringConvertible {
        let description: String
    }

    /// Runs git in `folder` and returns its output, or throws its error.
    @discardableResult
    func git(_ arguments: [String], in folder: String, timeout: Int = 30) async throws -> String {
        let result = try await Stackbar.run("git", ["-c", "color.ui=false"] + arguments, workingDirectory: folder, environment: Self.gitEnvironment, timeout: .seconds(timeout))
        if result.timedOut { throw GitFailure(description: "git \(arguments.first ?? "") took longer than \(timeout) s") }
        guard result.succeeded else {
            let text = (result.errorText.isEmpty ? result.text : result.errorText).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitFailure(description: Self.explain(text))
        }
        return result.text
    }

    /// git's error in fewer words, and what to do about the common ones.
    static func explain(_ text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("permission denied (publickey)") || lower.contains("could not read from remote") {
            return "The remote refused your SSH key. Check that your SSH agent has it (ssh-add -l)."
        }
        if lower.contains("terminal prompts disabled") || lower.contains("could not read username") || lower.contains("authentication failed") {
            return "The remote asked for a password. Sign in once with git in a terminal so the Keychain remembers it."
        }
        if lower.contains("could not resolve host") || lower.contains("connection timed out") || lower.contains("network is unreachable") {
            return "Can't reach the remote. Are you offline?"
        }
        if lower.contains("not possible to fast-forward") || lower.contains("diverging") { return "Your branch and its remote have both moved on. Merge or rebase it yourself." }
        if lower.contains("would be overwritten") { return "Your uncommitted changes would be overwritten. Commit or stash them first." }
        if lower.contains("xcode-select") || lower.contains("command line tools") { return "git needs the Xcode Command Line Tools: run xcode-select --install." }
        let first = text.split(separator: "\n").first { !$0.hasPrefix("hint:") }.map(String.init) ?? text
        return first.isEmpty ? "git failed" : String(first.prefix(300))
    }

    /// Runs `body` for every item, at most `width` at a time (the host runs
    /// four commands at once; one is left for clicks).
    func each<Item: Sendable, Result: Sendable>(_ items: [Item], width: Int = 3, _ body: @escaping @Sendable @MainActor (Item) async -> Result) async -> [Result] {
        var results: [(Int, Result)] = []
        await withTaskGroup(of: (Int, Result).self) { group in
            var next = 0
            func add() {
                guard next < items.count else { return }
                let index = next, item = items[index]
                next += 1
                group.addTask { (index, await body(item)) }
            }
            for _ in 0..<min(width, items.count) { add() }
            for await result in group {
                results.append(result)
                add()
            }
        }
        return results.sorted { $0.0 < $1.0 }.map(\.1)
    }

    // MARK: Parsing (static, so tests and previews don't need git)

    struct Status: Equatable {
        var branch: String?
        var upstream: String?
        var ahead = 0
        var behind = 0
        var changes = 0
        var conflicts = 0
    }

    /// `git status --porcelain=v2 --branch`.
    static func parseStatus(_ text: String) -> Status {
        var status = Status()
        for line in text.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") {
                let head = String(line.dropFirst("# branch.head ".count))
                status.branch = head == "(detached)" ? nil : head
            } else if line.hasPrefix("# branch.upstream ") {
                status.upstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                for part in line.dropFirst("# branch.ab ".count).split(separator: " ") {
                    if part.hasPrefix("+") { status.ahead = Int(part.dropFirst()) ?? 0 }
                    if part.hasPrefix("-") { status.behind = Int(part.dropFirst()) ?? 0 }
                }
            } else if line.hasPrefix("u ") {
                status.conflicts += 1
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") {
                status.changes += 1
            }
        }
        return status
    }

    /// `git worktree list --porcelain`: each worktree's path, branch and flags.
    static func parseWorktrees(_ text: String) -> [Worktree] {
        var trees: [Worktree] = []
        var current: Worktree?
        var bare = false
        func finish() {
            if let tree = current, !bare { trees.append(tree) }
            current = nil
            bare = false
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                finish()
                current = Worktree(path: String(line.dropFirst("worktree ".count)))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                current?.branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            } else if line == "bare" {
                bare = true
            } else if line.hasPrefix("locked") {
                current?.locked = true
            } else if line.hasPrefix("prunable") {
                current?.missing = true
            } else if line.isEmpty {
                finish()
            }
        }
        finish()
        if !trees.isEmpty { trees[0].isMain = true }
        return trees
    }

    /// `git for-each-ref` with name, upstream, track and tip date, tab-separated.
    static func parseBranches(_ text: String) -> [(branch: Branch, date: Date?)] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let name = fields.first, !name.isEmpty else { return nil }
            var branch = Branch(name: name)
            if fields.count > 1, !fields[1].isEmpty { branch.upstream = fields[1] }
            if fields.count > 2 {
                let track = fields[2]
                if track.contains("gone") { branch.gone = true }
                for part in track.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                    if part.hasPrefix("ahead ") { branch.ahead = Int(part.dropFirst(6)) ?? 0 }
                    if part.hasPrefix("behind ") { branch.behind = Int(part.dropFirst(7)) ?? 0 }
                }
            }
            let date = fields.count > 3 ? Double(fields[3]).map { Date(timeIntervalSince1970: $0) } : nil
            return (branch, date)
        }
    }

    /// The web page for a remote URL: git@github.com:o/r.git and
    /// https://github.com/o/r.git both give https://github.com/o/r.
    static func webURL(_ remote: String) -> String? {
        var text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(".git") { text.removeLast(4) }
        if text.hasPrefix("git@"), let colon = text.firstIndex(of: ":") {
            return "https://" + text[text.index(text.startIndex, offsetBy: 4)..<colon] + "/" + text[text.index(after: colon)...]
        }
        if text.hasPrefix("ssh://") {
            text.removeFirst(6)
            if let at = text.firstIndex(of: "@") { text = String(text[text.index(after: at)...]) }
            if let colon = text.firstIndex(of: ":"), let slash = text.firstIndex(of: "/"), colon < slash { text.removeSubrange(colon..<slash) }
            return "https://" + text
        }
        if text.hasPrefix("https://") || text.hasPrefix("http://") {
            if let at = text.firstIndex(of: "@"), let scheme = text.range(of: "://"), at > scheme.upperBound { text.removeSubrange(scheme.upperBound...at) }
            return text
        }
        return nil
    }

    // MARK: Refresh

    func refresh() async throws {
        defer { loaded = true }
        let reason = Stackbar.refreshReason
        if reason != .interval { lastResult = nil }
        folders = (try? await Stackbar.grantedFolders()) ?? folders
        let stale = scannedAt.map { Date().timeIntervalSince($0) > 3600 } ?? true
        if reason != .interval || stale || folders != scannedFolders {
            await scan()
        }
        if reason == .interval, let checkedAt, Date().timeIntervalSince(checkedAt) < 110 {
            await fetchDue(limit: 4)
            return
        }
        await checkAll()
        if reason != .launch { await fetchDue(limit: reason == .wake ? 6 : 4) }
    }

    /// Finds the repositories in every chosen folder and groups worktrees.
    func scan() async {
        problem = nil
        scannedFolders = folders
        guard !folders.isEmpty else { repositories = []; scannedAt = Date(); return }
        let skip = ["node_modules", ".build", "Pods", "vendor", "DerivedData", "Carthage", ".venv"]
        var pruned: [String] = ["("]
        for (index, name) in skip.enumerated() { pruned += (index == 0 ? [] : ["-o"]) + ["-name", name] }
        pruned += [")", "-prune", "-o", "-name", ".git", "-print", "-prune"]
        let found: [[String]] = await each(folders) { folder in
            let depth = max(1, min(4, self.depths[folder] ?? 2))
            guard let result = try? await Stackbar.run("find", [".", "-maxdepth", "\(depth + 1)"] + pruned, workingDirectory: folder, timeout: .seconds(30)) else { return [] }
            return result.text.split(separator: "\n").map { line in
                let relative = String(line.dropFirst(2).dropLast(5))   // "./a/b/.git" → "a/b"
                return line == "./.git" ? folder : folder + "/" + relative
            }
        }
        let candidates = Array(Set(found.flatMap { $0 })).sorted()
        // Each candidate's shared .git folder: worktrees of one repository
        // share it. Submodules (whose .git lives under .git/modules) are left
        // to their parent.
        let identified: [(String, String)?] = await each(candidates) { path in
            guard let text = try? await self.git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: path, timeout: 10) else { return nil }
            let common = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !common.contains("/.git/modules/") else { return nil }
            return (path, common)
        }
        var byCommon: [String: [String]] = [:]
        for case let (path, common)? in identified { byCommon[common, default: []].append(path) }
        let old = Dictionary(repositories.map { ($0.commonDir, $0) }, uniquingKeysWith: { first, _ in first })
        repositories = byCommon.map { common, paths in
            let mainPath = common.hasSuffix("/.git") ? String(common.dropLast(5)) : paths[0]
            var repo = old[common] ?? Repository(path: paths.contains(mainPath) ? mainPath : paths[0], commonDir: common)
            repo.path = paths.contains(mainPath) ? mainPath : paths.sorted()[0]
            return repo
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        scannedAt = Date()
    }

    /// Is `path` inside a folder git may run in?
    func isGranted(_ path: String) -> Bool {
        folders.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    /// Reads every repository's local state. Nothing here uses the network.
    func checkAll() async {
        let list = repositories
        let checked: [Repository] = await each(list) { repo in await self.check(repo) }
        repositories = checked
        checkedAt = Date()
        announce()
    }

    func check(_ repo: Repository) async -> Repository {
        var repo = repo
        do {
            let here = repo.path
            // One command at a time per repository: checkAll runs three
            // repositories side by side, and the host allows four commands.
            var trees = Self.parseWorktrees(try await git(["worktree", "list", "--porcelain"], in: here))
            let refs = Self.parseBranches(try await git(["for-each-ref", "--format=%(refname:short)%09%(upstream:short)%09%(upstream:track)%09%(committerdate:unix)", "refs/heads"], in: here))
            if repo.defaultBranch == nil {
                var found = (try? await git(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: here))?.trimmingCharacters(in: .whitespacesAndNewlines)
                // A clone of an empty repository has no origin/HEAD.
                for guess in ["origin/main", "origin/master"] where found == nil || found?.isEmpty == true {
                    if (try? await git(["rev-parse", "--verify", "--quiet", guess], in: here)) != nil { found = guess }
                }
                repo.defaultBranch = found
            }
            if repo.remoteURL == nil {
                repo.remoteURL = (try? await git(["remote", "get-url", "origin"], in: here))?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            var merged: Set<String> = []
            if let base = repo.defaultBranch, !base.isEmpty, trees.count > 1 || allBranches {
                let text = (try? await git(["for-each-ref", "--merged=\(base)", "--format=%(refname:short)", "refs/heads"], in: here)) ?? ""
                merged = Set(text.split(separator: "\n").map(String.init))
            }
            let defaultName = repo.defaultBranch.map { $0.split(separator: "/").dropFirst().joined(separator: "/") }
            var branches: [Branch] = []
            var dates: [String: Date] = [:]
            for (branch, date) in refs {
                var branch = branch
                branch.merged = merged.contains(branch.name) && branch.name != defaultName
                branches.append(branch)
                dates[branch.name] = date
            }
            // Ahead/behind from the shared refs; changes need git in the worktree.
            var statuses: [Status?] = []
            for tree in trees {
                guard !tree.missing, isGranted(tree.path) else { statuses.append(nil); continue }
                statuses.append((try? await git(["status", "--porcelain=v2", "--branch", "--untracked-files=no"], in: tree.path, timeout: 20)).map(Self.parseStatus))
            }
            for index in trees.indices {
                let ref = branches.first { $0.name == trees[index].branch }
                trees[index].upstream = ref?.upstream
                trees[index].ahead = ref?.ahead ?? 0
                trees[index].behind = ref?.behind ?? 0
                trees[index].upstreamGone = ref?.gone ?? false
                trees[index].merged = ref?.merged ?? false
                trees[index].lastCommit = trees[index].branch.flatMap { dates[$0] }
                if let status = statuses[index] {
                    trees[index].changes = status.changes
                    trees[index].conflicts = status.conflicts
                    trees[index].ahead = status.ahead
                    trees[index].behind = status.behind
                    if trees[index].upstream == nil { trees[index].upstream = status.upstream }
                }
            }
            repo.worktrees = trees
            repo.branches = branches
            repo.problem = trees.isEmpty ? "No working tree" : nil
        } catch {
            repo.problem = "\(error)"
        }
        return repo
    }

    /// Fetches the repositories whose turn has come, a few at a time, so a
    /// tick never holds up clicks for long.
    func fetchDue(limit: Int) async {
        guard fetchMinutes > 0, busy == nil else { return }
        let interval = Double(fetchMinutes) * 60
        let due = shown.filter { repo in
            repo.problem == nil && repo.main?.upstream != nil && (fetchedAt[repo.commonDir].map { Date().timeIntervalSince($0) >= interval } ?? true)
        }.sorted { (fetchedAt[$0.commonDir] ?? .distantPast) < (fetchedAt[$1.commonDir] ?? .distantPast) }
        guard !due.isEmpty else { return }
        await fetch(Array(due.prefix(limit)))
    }

    /// Fetches these repositories, then reads them again.
    func fetch(_ list: [Repository]) async {
        let outcomes: [(String, String?)] = await each(list) { repo in
            do {
                try await self.git(["fetch", "--prune", "--no-tags", "--quiet"], in: repo.path, timeout: 120)
                return (repo.commonDir, nil)
            } catch {
                return (repo.commonDir, "\(error)")
            }
        }
        for (common, failure) in outcomes {
            if failure == nil { fetchedAt[common] = Date() }
            if let index = repositories.firstIndex(where: { $0.commonDir == common }) {
                repositories[index] = await check(repositories[index])
                if let failure { repositories[index].problem = failure }
            }
        }
        announce()
    }

    /// Tells you about repositories that just fell behind, as one note.
    func announce() {
        let behind = repositories.filter { repo in
            guard let main = repo.main else { return false }
            return notifyMode == "diverged" ? main.behind > 0 && (main.ahead > 0 || main.isDirty) : main.behind > 0
        }.map(\.commonDir)
        let new = behind.filter { !wasBehind.contains($0) }
        if notifyMode != "off", !new.isEmpty, checkedAt != nil, !wasBehind.isEmpty || scannedAt.map({ Date().timeIntervalSince($0) > 120 }) == true {
            let names = repositories.filter { new.contains($0.commonDir) }.map(\.name)
            Stackbar.notify(names.count == 1 ? "\(names[0]) is behind its remote" : "\(names.count) repositories are behind",
                            body: names.prefix(6).joined(separator: ", "))
        }
        if behind != wasBehind { wasBehind = behind }
    }

    // MARK: Updating

    /// Pulls one working tree the way the settings say. Returns what
    /// happened in a few words, or throws why it couldn't.
    @discardableResult
    func pull(_ tree: Worktree, in repo: Repository, stash: Bool? = nil) async throws -> String {
        guard isGranted(tree.path) else { throw GitFailure(description: "\(tree.name) is outside the folders you chose") }
        guard tree.upstream != nil, !tree.upstreamGone else { throw GitFailure(description: "\(tree.branch ?? tree.name) has no remote branch to pull from") }
        guard tree.conflicts == 0 else { throw GitFailure(description: "Finish the merge or rebase in \(tree.name) first") }
        let useStash = stash ?? (dirtyMode == "stash")
        if tree.isDirty && !useStash { throw GitFailure(description: "\(tree.name) has uncommitted changes") }
        if fetchedAt[repo.commonDir].map({ Date().timeIntervalSince($0) > 60 }) ?? true {
            try await git(["fetch", "--prune", "--no-tags", "--quiet"], in: tree.path, timeout: 120)
            fetchedAt[repo.commonDir] = Date()
        }
        var stashed = false
        if tree.isDirty {
            let before = try await git(["stash", "list"], in: tree.path)
            try await git(["stash", "push", "--include-untracked", "-m", "Git Sync \(Date().formatted(date: .abbreviated, time: .shortened))"], in: tree.path)
            stashed = try await git(["stash", "list"], in: tree.path) != before
        }
        do {
            if pullMode == "rebase" {
                do {
                    try await git(["rebase", "@{u}"], in: tree.path, timeout: 120)
                } catch {
                    _ = try? await git(["rebase", "--abort"], in: tree.path)
                    throw error
                }
            } else {
                try await git(["merge", "--ff-only", "@{u}"], in: tree.path, timeout: 120)
            }
        } catch {
            if stashed { _ = try? await git(["stash", "pop"], in: tree.path) }
            throw error
        }
        if stashed {
            do {
                try await git(["stash", "pop"], in: tree.path)
            } catch {
                throw GitFailure(description: "Updated, but your changes didn't apply cleanly. They are still in the stash (git stash list).")
            }
        }
        return "Updated \(tree.branch ?? tree.name)"
    }

    /// One repository's pull, from its row.
    func pullRow(_ repo: Repository, tree: Worktree? = nil, stash: Bool? = nil) async {
        guard let tree = tree ?? repo.main else { return }
        guard busy == nil else { Stackbar.hud("\(busy!) is still running", isError: true); return }
        busy = "Updating \(repo.name)"
        defer { busy = nil }
        do {
            Stackbar.hud(try await pull(tree, in: repo, stash: stash))
        } catch {
            Stackbar.hud("\(repo.name): \(error)", isError: true)
        }
        await recheck(repo)
    }

    func push(_ repo: Repository, tree: Worktree? = nil, setUpstream: Bool = false) async {
        guard let tree = tree ?? repo.main else { return }
        guard busy == nil else { Stackbar.hud("\(busy!) is still running", isError: true); return }
        busy = "Pushing \(repo.name)"
        defer { busy = nil }
        do {
            try await git(setUpstream ? ["push", "--set-upstream", "origin", "HEAD"] : ["push"], in: tree.path, timeout: 180)
            Stackbar.hud("Pushed \(tree.branch ?? repo.name)")
        } catch {
            Stackbar.hud("\(repo.name): \(error)", isError: true)
        }
        await recheck(repo)
    }

    func recheck(_ repo: Repository) async {
        guard let index = repositories.firstIndex(where: { $0.commonDir == repo.commonDir }) else { return }
        repositories[index] = await check(repositories[index])
        if expanded == repo.commonDir { await loadIncoming(repositories[index]) }
    }

    /// Working trees Update All would pull, and the ones it leaves (with why).
    var updatePlan: (pull: [(Repository, Worktree)], skip: [(Repository, Worktree, String)]) {
        var pull: [(Repository, Worktree)] = []
        var skip: [(Repository, Worktree, String)] = []
        for repo in shown where repo.problem == nil {
            for tree in repo.worktrees where tree.isMain || (showWorktrees && updateWorktrees) {
                guard tree.behind > 0, !tree.missing else { continue }
                if tree.ahead > 0 { skip.append((repo, tree, "diverged")); continue }
                if tree.conflicts > 0 { skip.append((repo, tree, "merge in progress")); continue }
                if !isGranted(tree.path) { skip.append((repo, tree, "outside your folders")); continue }
                if tree.isDirty && dirtyMode != "stash" { skip.append((repo, tree, "uncommitted changes")); continue }
                pull.append((repo, tree))
            }
        }
        return (pull, skip)
    }

    /// Fast-forwards (or rebases) everything that is safe to, three at a time.
    func updateAll() async {
        guard busy == nil else { return }
        let plan = updatePlan
        guard !plan.pull.isEmpty else {
            lastResult = plan.skip.isEmpty ? "Everything is up to date." : "Nothing safe to update: " + Self.skipped(plan.skip)
            return
        }
        busy = "Updating \(plan.pull.count)"
        defer { busy = nil }
        let outcomes: [String?] = await each(plan.pull.map { ($0.0.commonDir, $0.1.path) }) { pair in
            guard let repo = self.repositories.first(where: { $0.commonDir == pair.0 }), let tree = repo.worktrees.first(where: { $0.path == pair.1 }) else { return "gone" }
            do { try await self.pull(tree, in: repo); return nil } catch { return "\(repo.name): \(error)" }
        }
        let failed = outcomes.compactMap { $0 }
        let updated = outcomes.count - failed.count
        var parts = ["Updated \(updated)"]
        if !plan.skip.isEmpty { parts.append("skipped \(plan.skip.count) (\(Self.skipped(plan.skip)))") }
        if !failed.isEmpty { parts.append("\(failed.count) failed") }
        lastResult = parts.joined(separator: ", ") + (failed.isEmpty ? "" : ": " + failed.joined(separator: "; "))
        Stackbar.hud(parts.joined(separator: ", "), isError: !failed.isEmpty)
        await checkAll()
    }

    static func skipped(_ skip: [(Repository, Worktree, String)]) -> String {
        Dictionary(grouping: skip, by: \.2).map { "\($0.value.count) \($0.key)" }.sorted().joined(separator: ", ")
    }

    func fetchAll() async {
        guard busy == nil else { return }
        busy = "Fetching \(shown.count)"
        defer { busy = nil }
        await fetch(shown.filter { $0.problem == nil || $0.main != nil })
        lastResult = "Fetched \(shown.count) repositor\(shown.count == 1 ? "y" : "ies")"
    }

    func loadIncoming(_ repo: Repository) async {
        guard let main = repo.main, main.behind > 0, isGranted(main.path) else { incoming[repo.commonDir] = []; return }
        let text = (try? await git(["log", "--no-decorate", "--format=%h %s", "-20", "HEAD..@{u}"], in: main.path)) ?? ""
        incoming[repo.commonDir] = text.split(separator: "\n").map(String.init)
    }

    func toggle(_ repo: Repository) async {
        if expanded == repo.commonDir { expanded = nil; return }
        expanded = repo.commonDir
        await loadIncoming(repo)
    }

    // MARK: Worktrees

    func removeWorktree(_ tree: Worktree, in repo: Repository) async {
        do {
            try await git(["worktree", "remove", tree.path], in: repo.path)
            Stackbar.hud("Removed \(tree.name)")
        } catch {
            Stackbar.hud("\(tree.name): \(error)", isError: true)
        }
        await recheck(repo)
    }

    var removable: [(Repository, Worktree)] {
        shown.flatMap { repo in repo.linked.filter(\.removable).map { (repo, $0) } }
    }

    /// What a clean-up asks before it runs: Stackbar holds the first press.
    var cleanUpConfirm: Confirm {
        "remove \(removable.count) merged worktree\(removable.count == 1 ? "" : "s")"
    }

    func cleanUp() async {
        let list = removable
        var removed = 0
        for (repo, tree) in list {
            if (try? await git(["worktree", "remove", tree.path], in: repo.path)) != nil { removed += 1 }
        }
        Stackbar.hud("Removed \(removed) of \(list.count) worktrees", isError: removed < list.count)
        await checkAll()
    }

    /// Where a new worktree for `branch` goes, by the setting.
    func worktreePath(for branch: String, in repo: Repository) -> String {
        let safe = branch.replacingOccurrences(of: "/", with: "-")
        switch worktreePlace {
        case "inside": return repo.path + "/.worktrees/" + safe
        case "folder" where !worktreeFolder.isEmpty: return worktreeFolder + "/" + repo.name + "-" + safe
        default: return (repo.path as NSString).deletingLastPathComponent + "/" + repo.name + "-" + safe
        }
    }

    func newWorktree(_ repoName: String?, branch: String?) async -> CommandResult {
        guard let repo = shown.first(where: { $0.name == repoName }) else { return .failure("Pick a repository") }
        let branch = (branch ?? "").trimmingCharacters(in: .whitespaces)
        guard !branch.isEmpty, !branch.contains(" "), !branch.hasPrefix("-") else { return .failure("Type a branch name") }
        let path = worktreePath(for: branch, in: repo)
        let exists = repo.branches.contains { $0.name == branch }
        do {
            try await git(exists ? ["worktree", "add", path, branch] : ["worktree", "add", "-b", branch, path], in: repo.path, timeout: 120)
            await recheck(repo)
            open(path)
            return .message("Made \(GitSync.tilde(path))")
        } catch {
            return .failure("\(error)")
        }
    }

    // MARK: Opening

    static let editors: [(name: String, id: String)] = [
        ("Finder", ""), ("Visual Studio Code", "com.microsoft.VSCode"), ("Cursor", "com.todesktop.230313mzl4w4u92"), ("Zed", "dev.zed.Zed"),
        ("Windsurf", "com.exafunction.windsurf"), ("Xcode", "com.apple.dt.Xcode"), ("Sublime Text", "com.sublimetext.4"), ("Nova", "com.panic.Nova"),
        ("IntelliJ IDEA", "com.jetbrains.intellij"), ("Fork", "com.DanPristupov.Fork"), ("Tower", "com.fournova.Tower3"), ("GitHub Desktop", "com.github.GitHubClient"),
    ]
    static let terminals: [(name: String, id: String)] = [
        ("Terminal", "com.apple.Terminal"), ("iTerm", "com.googlecode.iterm2"), ("Ghostty", "com.mitchellh.ghostty"), ("Warp", "dev.warp.Warp-Stable"), ("WezTerm", "com.github.wez.wezterm"),
    ]

    func open(_ path: String, with app: String? = nil) {
        let bundle = app ?? editor
        Task { @MainActor in
            do {
                try await Stackbar.open(path, with: bundle.isEmpty ? "com.apple.finder" : bundle)
            } catch {
                Stackbar.hud("Couldn't open it: \(error)", isError: true)
            }
        }
    }

    func web(_ repo: Repository, branch: String? = nil) -> String? {
        guard let base = repo.remoteURL.flatMap(Self.webURL) else { return nil }
        guard let branch, branch != repo.defaultBranch?.split(separator: "/").dropFirst().joined(separator: "/") else { return base }
        let encoded = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
        return base.contains("gitlab") ? base + "/-/compare/" + encoded : base + "/compare/" + encoded
    }

    // MARK: Words

    var shown: [Repository] { repositories.filter { !hidden.contains($0.commonDir) } }

    var behindCount: Int { shown.filter { ($0.main?.behind ?? 0) > 0 }.count }
    var aheadCount: Int { shown.filter { ($0.main?.ahead ?? 0) > 0 }.count }
    var dirtyCount: Int { shown.filter { $0.main?.isDirty == true }.count }

    /// A path with the home folder shown as ~.
    static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86400))d ago"
    }

    func arrows(_ tree: Worktree) -> String? {
        let parts = [tree.behind > 0 ? "↓\(tree.behind)" : nil, tree.ahead > 0 ? "↑\(tree.ahead)" : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    func subtitle(_ repo: Repository) -> String {
        guard let main = repo.main else { return repo.problem ?? "" }
        var parts: [String] = [main.branch ?? "detached HEAD"]
        if let arrows = arrows(main) { parts.append(arrows) }
        if let changes = main.changes, changes > 0 { parts.append("\(changes) changed") }
        if main.conflicts > 0 { parts.append("\(main.conflicts) in conflict") }
        if showWorktrees, !repo.linked.isEmpty {
            let clean = repo.linked.filter(\.removable).count
            parts.append("\(repo.linked.count) worktree\(repo.linked.count == 1 ? "" : "s")" + (clean > 0 ? " · \(clean) to clean up" : ""))
        }
        parts.append("fetched " + Self.ago(fetchedAt[repo.commonDir]))
        return parts.joined(separator: " · ")
    }

    // MARK: Rows

    func repoRow(_ repo: Repository) -> Row {
        let state = state(repo)
        var row = Row(repo.name, subtitle: repo.problem ?? subtitle(repo), symbol: Self.symbol(state), key: repo.commonDir)
        switch state {
        case .behind:
            row = row.badge("Behind", role: .warning).action("Pull", shortcut: "cmd+return") { await self.pullRow(repo) }
        case .ahead:
            row = row.badge("Not pushed", role: .accent).action("Push", shortcut: "cmd+return") { await self.push(repo) }
        case .diverged:
            row = row.badge("Diverged", role: .critical).action("Open", shortcut: "cmd+return") { self.open(repo.path) }
        case .conflicts:
            row = row.badge("Conflicts", role: .critical).action("Open", shortcut: "cmd+return") { self.open(repo.path) }
        case .dirty:
            row = row.badge("Changes", role: .secondary).action("Open", shortcut: "cmd+return") { self.open(repo.path) }
        case .noUpstream:
            row = row.badge(repo.main?.upstreamGone == true ? "Remote gone" : "No upstream", role: .secondary).action("Open", shortcut: "cmd+return") { self.open(repo.path) }
        case .upToDate, .problem:
            row = row.action("Open", shortcut: "cmd+return") { self.open(repo.path) }
        }
        if let main = repo.main, main.isDirty, main.behind > 0, main.ahead == 0, dirtyMode != "stash" {
            row = row.action("Stash, pull and restore") { await self.pullRow(repo, stash: true) }
        }
        if let main = repo.main, main.upstream == nil, main.branch != nil {
            row = row.action("Push and set upstream") { await self.push(repo, setUpstream: true) }
        }
        row = row.action(expanded == repo.commonDir ? "Hide details" : (repo.linked.isEmpty ? "Show incoming commits" : "Show commits and worktrees"), shortcut: "cmd+i") { await self.toggle(repo) }
            .action("Fetch", shortcut: "cmd+r") { await self.fetch([repo]) }
        if state != .behind, state != .diverged, (repo.main?.behind ?? 0) > 0 { row = row.action("Pull") { await self.pullRow(repo) } }
        if state != .ahead, state != .diverged, (repo.main?.ahead ?? 0) > 0, repo.main?.upstream != nil { row = row.action("Push") { await self.push(repo) } }
        if !editor.isEmpty, let name = Self.editors.first(where: { $0.id == editor })?.name {
            row = row.action("Open in \(name)") { self.open(repo.path) }
        }
        row = row.action("Open in \(Self.terminals.first { $0.id == terminal }?.name ?? "Terminal")") { self.open(repo.path, with: self.terminal) }
            .action("Show in Finder") { self.open(repo.path, with: "com.apple.finder") }
        if let page = web(repo, branch: repo.main?.branch) {
            row = row.action("Open on the web") { Stackbar.open(page) }
        }
        row = row.action("Copy path") { Stackbar.copy(repo.path) }
        if let branch = repo.main?.branch { row = row.action("Copy branch name") { Stackbar.copy(branch) } }
        return row.action("Hide \(repo.name)") { self.hidden.append(repo.commonDir) }
    }

    func worktreeRow(_ tree: Worktree, in repo: Repository) -> Row {
        var labels: [(String, Role)] = []
        if tree.isMain { labels.append(("Main", .secondary)) }
        if tree.missing { labels.append(("Missing", .warning)) }
        if tree.madeByAgent { labels.append(("Agent", .accent)) }
        if tree.locked { labels.append(("Locked", .secondary)) }
        if tree.removable { labels.append(("Merged", .success)) }
        var parts: [String] = [tree.branch ?? "detached HEAD"]
        if let arrows = arrows(tree) { parts.append(arrows) }
        if let changes = tree.changes { if changes > 0 { parts.append("\(changes) changed") } } else if !tree.missing { parts.append("changes unknown: outside your folders") }
        if let date = tree.lastCommit { parts.append("last commit " + Self.ago(date)) }
        var row = Row(tree.isMain ? "\(tree.name) (main)" : tree.name, subtitle: parts.joined(separator: " · "), symbol: tree.missing ? "questionmark.folder" : "folder", key: "tree-\(tree.path)")
        for label in labels.prefix(3) { row = row.badge(label.0, role: label.1) }
        if tree.missing {
            return row.action("Prune") {
                do { try await self.git(["worktree", "prune"], in: repo.path) } catch { Stackbar.hud("\(error)", isError: true) }
                await self.recheck(repo)
            }.hiddenFromPalette()
        }
        row = row.action("Open") { self.open(tree.path) }
            .action("Open in \(Self.terminals.first { $0.id == terminal }?.name ?? "Terminal")") { self.open(tree.path, with: self.terminal) }
        if tree.behind > 0 && tree.ahead == 0 { row = row.action("Pull") { await self.pullRow(repo, tree: tree) } }
        if tree.ahead > 0 && tree.upstream != nil { row = row.action("Push") { await self.push(repo, tree: tree) } }
        if tree.changes == nil && !tree.missing {
            row = row.action("Add its folder…") {
                if try await Stackbar.chooseFolder(prompt: "Choose this worktree's folder (or one that holds it)", startingAt: (tree.path as NSString).deletingLastPathComponent) != nil {
                    self.folders = try await Stackbar.grantedFolders()
                    await self.recheck(repo)
                }
            }
        }
        row = row.action("Copy path") { Stackbar.copy(tree.path) }
        if let branch = tree.branch { row = row.action("Copy branch name") { Stackbar.copy(branch) } }
        if tree.locked { row = row.action("Unlock") { _ = try? await self.git(["worktree", "unlock", tree.path], in: repo.path); await self.recheck(repo) } }
        if !tree.isMain && !tree.locked && tree.changes == 0 && tree.conflicts == 0 {
            row = row.action("Remove worktree") { await self.removeWorktree(tree, in: repo) }
        }
        return row.hiddenFromPalette()
    }

    static func symbol(_ state: State) -> String {
        switch state {
        case .conflicts: return "exclamationmark.triangle.fill"
        case .diverged: return "arrow.triangle.branch"
        case .behind: return "arrow.down.circle.fill"
        case .ahead: return "arrow.up.circle.fill"
        case .dirty: return "pencil.circle"
        case .noUpstream: return "icloud.slash"
        case .upToDate: return "checkmark.circle"
        case .problem: return "questionmark.circle"
        }
    }

    @ViewBuilder func details(_ repo: Repository) -> ViewContent {
        let commits = incoming[repo.commonDir] ?? []
        if !commits.isEmpty {
            ForEach(Array(commits.enumerated())) { pair in
                Row(String(pair.element.drop { $0 != " " }.dropFirst()), subtitle: "incoming · " + String(pair.element.prefix { $0 != " " }), symbol: "arrow.down", key: "commit-\(repo.commonDir)-\(pair.offset)")
                    .action("Copy") { Stackbar.copy(pair.element) }
                    .hiddenFromPalette()
            }
        }
        if showWorktrees, repo.worktrees.count > 1 {
            ForEach(repo.worktrees) { tree in worktreeRow(tree, in: repo) }
        }
    }

    @ViewBuilder func repoList(_ repos: [Repository]) -> ViewContent {
        List(searchable: true) {
            ForEach(State.allCases.filter { state in repos.contains { self.state($0) == state } }) { state in
                Section(state.title) {
                    ForEach(repos.filter { self.state($0) == state }) { repo in
                        repoRow(repo)
                        if expanded == repo.commonDir { details(repo) }
                    }
                }
            }
        }
    }

    // MARK: Surfaces

    var menuBar: ViewContent {
        let count = behindCount + (countAhead ? aheadCount : 0)
        if busy != nil {
            Label("", symbol: "arrow.triangle.2.circlepath").role(.secondary)
        } else if menuBarMode == "never" || (menuBarMode == "behind" && count == 0) {
            // Nothing: the item leaves the menu bar until something is behind.
        } else if count > 0 {
            Label("\(count)", symbol: "arrow.down.circle")
        } else {
            Label("", symbol: "arrow.triangle.branch").role(.secondary)
        }
    }

    var headline: String {
        if folders.isEmpty { return "Choose where your code is" }
        if behindCount > 0 { return "\(behindCount) behind" }
        if aheadCount > 0 { return "\(aheadCount) not pushed" }
        return "All in sync"
    }

    var panel: ViewContent {
        VStack(spacing: Space.m) {
            PanelHeader(headline, subtitle: loaded ? "\(shown.count) repositor\(shown.count == 1 ? "y" : "ies")" + (checkedAt.map { " · checked \(Self.ago($0))" } ?? "") : "Looking…",
                        symbol: "arrow.triangle.branch", theme: theme) {
                if !folders.isEmpty {
                    IconButton("arrow.clockwise", label: "Fetch all", theme: theme, prominence: .tinted, key: "fetch-all") { await self.fetchAll() }
                }
            }
            if folders.isEmpty {
                chooseFolders
            } else {
                HeroCard(theme: behindCount > 0 ? theme : .success, look: .glow) {
                    HStack(spacing: Space.l) {
                        HeroStat("Behind", value: "\(behindCount)", theme: theme, live: behindCount > 0, symbol: "arrow.down")
                        HeroStat("Not pushed", value: "\(aheadCount)", theme: .info, symbol: "arrow.up")
                        HeroStat("Changes", value: "\(dirtyCount)", theme: .neutral, symbol: "pencil")
                        Spacer()
                    }
                }
                let plan = updatePlan
                if !plan.pull.isEmpty {
                    ActionButton("Update \(plan.pull.count) safely", symbol: "arrow.down.circle.fill", theme: theme, prominent: true, fillWidth: true, key: "update-all") { await self.updateAll() }
                }
                if let busy { Banner("\(busy)…", symbol: "arrow.triangle.2.circlepath", theme: .info) }
                if let lastResult { Banner(lastResult, symbol: "info.circle", theme: .info) }
                if let problem { Banner(problem) }
                if shown.isEmpty, loaded {
                    EmptyState("No repositories found", symbol: "magnifyingglass", message: "None in the folders you chose, \(folders.count == 1 ? "" : "each ")up to \(depths.values.max() ?? 2) levels deep. Change how deep to look in Settings, or add another folder.", theme: theme) {
                        ActionButton("Add a Folder…", symbol: "folder.badge.plus", theme: theme) { await self.addFolder() }
                    }
                } else {
                    repoList(shown)
                }
                if showWorktrees, !removable.isEmpty {
                    ActionButton("Clean Up \(removable.count) Merged Worktree\(removable.count == 1 ? "" : "s")", symbol: "trash", theme: .neutral, fillWidth: true, key: "clean-up", confirm: cleanUpConfirm) { await self.cleanUp() }
                }
            }
        }
    }

    @ViewBuilder var chooseFolders: ViewContent {
        EmptyState("Where is your code?", symbol: "folder.badge.plus",
                   message: "Choose the folders your repositories are in. git runs only in the folders you choose, and you can remove them in Settings.", theme: theme) {
            ActionButton("Choose a Folder…", symbol: "folder.badge.plus", theme: theme, prominent: true) { await self.addFolder() }
        }
        Text("Common places: ~/Developer, ~/code, ~/src, ~/Projects, ~/repos, ~/GitHub.").style(.caption).role(.secondary)
    }

    func addFolder(startingAt: String = "~") async {
        do {
            guard let chosen = try await Stackbar.chooseFolder(prompt: "Choose a folder that holds your git repositories", startingAt: startingAt) else { return }
            folders = try await Stackbar.grantedFolders()
            busy = "Looking in \(chosen.name)"
            defer { busy = nil }
            await scan()
            await checkAll()
        } catch {
            problem = "\(error)"
        }
    }

    var window: ViewContent {
        VStack(spacing: Space.m) {
            if folders.isEmpty {
                chooseFolders
            } else {
                repoList(shown)
                if showWorktrees {
                    let trees = shown.flatMap { repo in repo.linked.map { (repo, $0) } }.sorted { ($0.1.lastCommit ?? .distantPast) < ($1.1.lastCommit ?? .distantPast) }
                    if !trees.isEmpty {
                        List {
                            Section("Worktrees, oldest first (\(trees.count))") {
                                ForEach(trees) { pair in worktreeRow(pair.1, in: pair.0) }
                            }
                        }
                    }
                }
                let branches = shown.flatMap { repo in repo.branches.filter { allBranches || $0.gone }.map { (repo, $0) } }
                if !branches.isEmpty {
                    List(searchable: true) {
                        Section(allBranches ? "Every local branch" : "Branches whose remote is gone") {
                            ForEach(branches) { pair in branchRow(pair.1, in: pair.0) }
                        }
                    }
                }
            }
        }
    }

    func branchRow(_ branch: Branch, in repo: Repository) -> Row {
        let arrows = [branch.behind > 0 ? "↓\(branch.behind)" : nil, branch.ahead > 0 ? "↑\(branch.ahead)" : nil].compactMap { $0 }.joined(separator: " ")
        var row = Row(branch.name, subtitle: [repo.name, branch.upstream ?? "no upstream", arrows.isEmpty ? nil : arrows].compactMap { $0 }.joined(separator: " · "), symbol: "arrow.triangle.branch", key: "branch-\(repo.commonDir)-\(branch.name)")
        if branch.gone { row = row.badge("Remote gone", role: .warning) }
        if branch.merged { row = row.badge("Merged", role: .success) }
        row = row.action("Copy branch name") { Stackbar.copy(branch.name) }
        let checkedOut = repo.worktrees.contains { $0.branch == branch.name }
        if (branch.gone || branch.merged) && !checkedOut {
            // -d, never -D: git refuses a branch that isn't merged.
            row = row.action("Delete branch") {
                do { try await self.git(["branch", "-d", branch.name], in: repo.path); Stackbar.hud("Deleted \(branch.name)") } catch { Stackbar.hud("\(error)", isError: true) }
                await self.recheck(repo)
            }
        }
        return row.hiddenFromPalette()
    }

    var widget: ViewContent {
        VStack(spacing: Space.s) {
            HStack(spacing: Space.s) {
                StatTile("Behind", value: "\(behindCount)", theme: theme, emphasized: behindCount > 0)
                StatTile("Not pushed", value: "\(aheadCount)", theme: .info)
                StatTile("Changes", value: "\(dirtyCount)")
            }
            if !updatePlan.pull.isEmpty {
                Button("Update \(updatePlan.pull.count)", symbol: "arrow.down.circle", key: "widget-update") { await self.updateAll() }
            } else {
                Text(folders.isEmpty ? "Choose your code folders in the panel" : "All in sync").role(.secondary).typography(.caption)
            }
        }
        .frame(fillWidth: true, fillHeight: true)
    }

    static let fetchChoices: [(String, Int)] = [("Every 5 minutes", 5), ("Every 15 minutes", 15), ("Every 30 minutes", 30), ("Every hour", 60), ("Only when I ask", 0)]

    var settings: ViewContent {
        Section("Where your code is") {
            if folders.isEmpty { Text("No folders yet.").role(.secondary) }
            ForEach(folders) { folder in
                Picker(GitSync.tilde(folder), options: ["1 level deep", "2 levels deep", "3 levels deep", "4 levels deep"],
                       selection: "\(depths[folder] ?? 2) level\((depths[folder] ?? 2) == 1 ? "" : "s") deep") { chosen in
                    self.depths[folder] = Int(chosen.prefix(1)) ?? 2
                    await self.scan()
                    await self.checkAll()
                }
            }
            Button("Add a Folder…", symbol: "folder.badge.plus") { await self.addFolder() }
            Text("Git Sync looks for repositories this many folders down. A folder that is itself a repository works too. To stop git running in a folder, remove it under Folders you chose.").style(.caption).role(.secondary)
        }
        Section("Updating") {
            Picker("Check the remote", options: Self.fetchChoices.map(\.0), selection: Self.fetchChoices.first { $0.1 == fetchMinutes }?.0 ?? "Every 15 minutes") { chosen in
                self.fetchMinutes = Self.fetchChoices.first { $0.0 == chosen }?.1 ?? 15
            }
            Picker("Pull by", options: ["Fast-forward only", "Rebasing my commits"], selection: pullMode == "rebase" ? "Rebasing my commits" : "Fast-forward only") { chosen in
                self.pullMode = chosen == "Rebasing my commits" ? "rebase" : "ff"
            }
            Picker("Uncommitted changes", options: ["Skip the repository", "Stash, pull, then restore", "Ask me on the row"],
                   selection: dirtyMode == "stash" ? "Stash, pull, then restore" : dirtyMode == "ask" ? "Ask me on the row" : "Skip the repository") { chosen in
                self.dirtyMode = chosen.hasPrefix("Stash") ? "stash" : chosen.hasPrefix("Ask") ? "ask" : "skip"
            }
            Text("Checking the remote (git fetch) never changes your files. Pulls never make a merge commit, diverged repositories always wait for you, and nothing is force-pushed. If restoring stashed changes conflicts, they stay in the stash.").style(.caption).role(.secondary)
        }
        Section("Worktrees") {
            Toggle("Show worktrees under their repository", isOn: showWorktrees) { self.showWorktrees = $0 }
            Toggle("Update All includes worktrees", isOn: updateWorktrees) { self.updateWorktrees = $0 }
            Picker("New worktrees go", options: ["Next to the repository", "In a .worktrees folder inside it", "In a folder I choose"],
                   selection: worktreePlace == "inside" ? "In a .worktrees folder inside it" : worktreePlace == "folder" ? "In a folder I choose" : "Next to the repository") { chosen in
                if chosen.hasPrefix("In a folder") {
                    if let picked = try await Stackbar.chooseFolder(prompt: "Choose where new worktrees go") {
                        self.worktreeFolder = picked.path
                        self.worktreePlace = "folder"
                        self.folders = try await Stackbar.grantedFolders()
                    }
                } else {
                    self.worktreePlace = chosen.hasPrefix("In a .worktrees") ? "inside" : "sibling"
                }
            }
            if worktreePlace == "folder", !worktreeFolder.isEmpty { LabeledContent("Folder", value: GitSync.tilde(worktreeFolder)) }
        }
        Section("Showing") {
            Toggle("List every local branch in the window", isOn: allBranches) { on in
                self.allBranches = on
                await self.checkAll()
            }
            Picker("Menu bar", options: ["When something is behind", "Always", "Never"],
                   selection: menuBarMode == "always" ? "Always" : menuBarMode == "never" ? "Never" : "When something is behind") { chosen in
                self.menuBarMode = chosen == "Always" ? "always" : chosen == "Never" ? "never" : "behind"
            }
            Toggle("Count unpushed repositories in the menu bar", isOn: countAhead) { self.countAhead = $0 }
            Picker("Open repositories in", options: Self.editors.map(\.name), selection: Self.editors.first { $0.id == editor }?.name ?? "Finder") { chosen in
                self.editor = Self.editors.first { $0.name == chosen }?.id ?? ""
            }
            Picker("Terminal", options: Self.terminals.map(\.name), selection: Self.terminals.first { $0.id == terminal }?.name ?? "Terminal") { chosen in
                self.terminal = Self.terminals.first { $0.name == chosen }?.id ?? "com.apple.Terminal"
            }
        }
        Section("Notifications") {
            Picker("Notify me", options: ["Never", "When a repository falls behind", "Only when I have unpushed work too"],
                   selection: notifyMode == "behind" ? "When a repository falls behind" : notifyMode == "diverged" ? "Only when I have unpushed work too" : "Never") { chosen in
                self.notifyMode = chosen.hasPrefix("When") ? "behind" : chosen.hasPrefix("Only") ? "diverged" : "off"
            }
        }
        Section("Hidden repositories") {
            if hidden.isEmpty { Text("None. Hide one from its menu in the panel.").role(.secondary) }
            ForEach(hidden) { common in
                Row(((common as NSString).deletingLastPathComponent as NSString).lastPathComponent, subtitle: GitSync.tilde(common), symbol: "eye.slash", key: "hidden-\(common)")
                    .action("Show again") { self.hidden.removeAll { $0 == common } }
            }
        }
    }

    // MARK: Commands

    var commands: [Command] {
        Command("repositories", title: "Search Local Repositories", subtitle: "Behind, ahead or changed, with Pull and Push", symbol: "arrow.triangle.branch", keywords: ["git", "repo", "sync", "pull"])
            .view(search: { _ in
                if self.checkedAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true { await self.checkAll() }
            }) { _ in
                if self.folders.isEmpty {
                    ContentUnavailableView("Choose your code folders first", symbol: "folder.badge.plus", message: "Open Git Sync from the menu bar and choose where your repositories are.")
                } else {
                    List(searchable: true) {
                        ForEach(self.shown) { repo in self.repoRow(repo).preview(text: self.previewText(repo), caption: repo.path) }
                    }
                }
            }
            .rootSearch(section: "Repositories")
        Command("update-all", title: "Update All Repositories", subtitle: "Fast-forward every repository that is behind and safe to", symbol: "arrow.down.circle", keywords: ["git", "pull", "sync"]) { _ in
            await self.updateAll()
            return .message(self.lastResult ?? "Done")
        }
        Command("fetch-all", title: "Fetch All Repositories", symbol: "arrow.clockwise", keywords: ["git", "fetch", "sync"]) { _ in
            await self.fetchAll()
            return .message(self.lastResult ?? "Done")
        }
        Command("worktrees", title: "Search Worktrees", subtitle: "Every worktree by branch or folder", symbol: "folder", keywords: ["git", "worktree", "branch"])
            .view(search: { _ in
                if self.checkedAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true { await self.checkAll() }
            }) { _ in
                let trees = self.shown.flatMap { repo in repo.linked.map { (repo, $0) } }
                if trees.isEmpty {
                    ContentUnavailableView("No worktrees", symbol: "folder", message: "Repositories with linked worktrees show them here.")
                } else {
                    List(searchable: true) {
                        ForEach(trees) { pair in
                            Row(pair.1.branch ?? pair.1.name, subtitle: "\(pair.0.name) · \(GitSync.tilde(pair.1.path))", symbol: "folder", key: "wt-\(pair.1.path)")
                                .action("Open") { self.open(pair.1.path) }
                                .action("Open in \(Self.terminals.first { $0.id == self.terminal }?.name ?? "Terminal")") { self.open(pair.1.path, with: self.terminal) }
                                .action("Copy path") { Stackbar.copy(pair.1.path) }
                        }
                    }
                }
            }
        Command("clean-up", title: "Clean Up Worktrees", subtitle: "Remove worktrees whose branch is merged", symbol: "trash", keywords: ["git", "worktree", "prune"])
            .view(search: { _ in await self.checkAll() }) { _ in
                let left = self.shown.flatMap { repo in repo.linked.filter { !$0.removable && !$0.isMain }.map { (repo, $0) } }
                if self.removable.isEmpty {
                    ContentUnavailableView("Nothing to clean up", symbol: "checkmark.circle", message: "No worktree is both merged and free of changes.")
                } else {
                    List {
                        Section("Merged and clean") {
                            Row("Remove All \(self.removable.count)", symbol: "trash", key: "clean-all").action("Remove All", confirm: self.cleanUpConfirm) { await self.cleanUp() }
                            ForEach(self.removable) { pair in self.worktreeRow(pair.1, in: pair.0) }
                        }
                        if !left.isEmpty {
                            Section("Kept") {
                                ForEach(left) { pair in
                                    Row(pair.1.name, subtitle: pair.1.isDirty ? "has uncommitted changes" : pair.1.locked ? "locked" : pair.1.changes == nil ? "outside your folders" : "not merged", symbol: "folder", key: "kept-\(pair.1.path)")
                                        .action("Open") { self.open(pair.1.path) }
                                }
                            }
                        }
                    }
                }
            }
        Command("new-worktree", title: "New Git Worktree", symbol: "plus.square.on.square", keywords: ["git", "worktree", "branch"]) { invocation in
            await self.newWorktree(invocation["repo"], branch: invocation["branch"])
        }
        .argument("repo", placeholder: "Repository", options: shown.map(\.name))
        .argument("branch", placeholder: "Branch (new or existing)")
    }

    func previewText(_ repo: Repository) -> String {
        var lines = [subtitle(repo)]
        let commits = incoming[repo.commonDir] ?? []
        if !commits.isEmpty { lines.append("Incoming:"); lines += commits.prefix(8).map { "  " + $0 } }
        if !repo.linked.isEmpty { lines.append("Worktrees:"); lines += repo.linked.map { "  \($0.name) · \($0.branch ?? "detached")" + (arrows($0).map { " · " + $0 } ?? "") } }
        return lines.joined(separator: "\n")
    }

    // MARK: Agents

    var tools: [AgentTool] {
        AgentTool("repo_status", description: "My local git repositories with their branch, how far behind or ahead of the remote, and uncommitted changes, one per line") { _ in
            if !self.loaded { try await self.refresh() }
            if self.folders.isEmpty { return "No code folders chosen yet: open Git Sync and choose where your repositories are." }
            return self.shown.isEmpty ? "No repositories found." : self.shown.map { repo in
                "\(repo.name) (\(repo.path)): \(self.state(repo).title.lowercased()); \(self.subtitle(repo))"
            }.joined(separator: "\n")
        }
    }

    // MARK: Previews

    static let previews: [PreviewScene<GitSync>] = [
        PreviewScene("hero", "Which repositories are behind, and one click to update them") { plugin in sample(plugin) },
        PreviewScene("worktrees", "Every worktree under its repository, and the merged ones to clean up") { plugin in
            sample(plugin)
            plugin.expanded = plugin.repositories.first { $0.name == "stackbar" }?.commonDir
        },
        PreviewScene("dashboard", "Repositories, worktrees and stale branches", surface: .window) { plugin in sample(plugin) },
        PreviewScene("widget", "Behind and unpushed at a glance", surface: .widget) { plugin in sample(plugin) },
    ]

    static func sample(_ plugin: GitSync) {
        let now = Date()
        let root = "/Users/you/Developer"
        func tree(_ name: String, _ branch: String, behind: Int = 0, ahead: Int = 0, changes: Int = 0, main: Bool = true, path: String? = nil, merged: Bool = false, days: Double = 0) -> Worktree {
            Worktree(path: path ?? "\(root)/\(name)", branch: branch, upstream: "origin/\(branch)", ahead: ahead, behind: behind, changes: changes, isMain: main, merged: merged, lastCommit: now.addingTimeInterval(-days * 86400))
        }
        func repo(_ name: String, _ trees: [Worktree], remote: String) -> Repository {
            Repository(path: "\(root)/\(name)", commonDir: "\(root)/\(name)/.git", worktrees: trees, remoteURL: remote, defaultBranch: "origin/main")
        }
        plugin.folders = [root]
        plugin.repositories = [
            repo("api", [tree("api", "main", behind: 12)], remote: "git@github.com:acme/api.git"),
            repo("web", [tree("web", "main", behind: 3)], remote: "git@github.com:acme/web.git"),
            repo("stackbar", [
                tree("stackbar", "main", behind: 2),
                tree("stackbar", "feature/git-sync", ahead: 4, main: false, path: "\(root)/stackbar/.claude/worktrees/git-sync", days: 0.1),
                tree("stackbar", "fix/palette", main: false, path: "\(root)/stackbar-fix-palette", merged: true, days: 9),
            ], remote: "git@github.com:navbytes/stackbar.git"),
            repo("ios", [tree("ios", "release/2.4", behind: 1, changes: 5)], remote: "git@github.com:acme/ios.git"),
            repo("infra", [tree("infra", "main", ahead: 2)], remote: "git@gitlab.com:acme/infra.git"),
            repo("design-tokens", [tree("design-tokens", "main", behind: 6, ahead: 1)], remote: "https://github.com/acme/design-tokens.git"),
            repo("dotfiles", [tree("dotfiles", "main", changes: 2)], remote: "git@github.com:you/dotfiles.git"),
            repo("blog", [tree("blog", "main")], remote: "git@github.com:you/blog.git"),
        ]
        for repo in plugin.repositories { plugin.fetchedAt[repo.commonDir] = now.addingTimeInterval(-4 * 60) }
        plugin.incoming["\(root)/stackbar/.git"] = ["9905abc Folders the user chooses for a plugin", "b5690a8 Release 0.33.0"]
        plugin.checkedAt = now
        plugin.scannedAt = now
        plugin.loaded = true
    }
}
