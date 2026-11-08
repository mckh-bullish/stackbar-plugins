import StackbarKit
import Foundation

/// What OpenRouter is costing you: today, this week and this month from your
/// key, its limit or budget, and, with a management key, the credit balance,
/// a month of daily spend and the models it went on.
///
/// OPENROUTER_API_KEY is any OpenRouter key: `/api/v1/key` answers with that
/// key's own spend and limit. OPENROUTER_MANAGEMENT_KEY is optional: only a
/// management key may read the balance (`/api/v1/credits`) and the account's
/// activity (`/api/v1/activity`). Both stay in the Keychain, and the plugin
/// reaches openrouter.ai and nothing else. Days are UTC days, as OpenRouter
/// counts them. The last good numbers stay on screen while it can't be reached.
@main
final class OpenRouter: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.openrouter",
        name: "OpenRouter",
        version: "1.0.0",
        summary: "Spend, credits, limits and model mix for your OpenRouter account, with charts.",
        surfaces: [.menuBar, .panel, .widget, .settings],
        triggers: [.launch, .minutes(2), .wake],
        capabilities: [.network("openrouter.ai"), .secret(name: "OPENROUTER_API_KEY"), .secret(name: "OPENROUTER_MANAGEMENT_KEY")],
        minimumStackbar: "0.17.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Monitoring/OpenRouter",
        accent: .indigo,
        symbol: "point.3.connected.trianglepath.dotted"
    )

    static let api = "https://openrouter.ai/api/v1"

    // MARK: Previews

    static let previews: [PreviewScene<OpenRouter>] = [
        PreviewScene("hero", "Spend, credits and models for OpenRouter") { plugin in sample(plugin) },
        PreviewScene("key-only", "Just an API key: today, this week and its limit") { plugin in
            sample(plugin)
            plugin.credits = nil
            plugin.days = [:]
            plugin.models = []
            plugin.hasManagementKey = false
        },
        PreviewScene("widget", "Today's spend and credits on the desktop", surface: .widget) { plugin in sample(plugin) },
    ]

    /// A month of a developer's usage: weekdays busy, weekends quiet.
    static func sample(_ plugin: OpenRouter) {
        plugin.connected = true
        plugin.hasManagementKey = true
        var days: [String: Day] = [:]
        for offset in -30 ... -1 {
            let weekday = utc.component(.weekday, from: Date().addingTimeInterval(Double(offset) * 86400))
            let weekend = weekday == 1 || weekday == 7
            let wobble = 0.7 + 0.6 * abs(sin(Double(offset) * 1.3))
            let spend = (weekend ? 0.6 : 3.4) * wobble
            days[day(offset)] = Day(spend: spend, tokens: spend / 3.1 * 1e6, requests: (spend * 140).rounded())
        }
        plugin.days = days
        plugin.models = [
            Model(name: "anthropic/claude-sonnet-4.5", spend: 41.2, tokens: 11.8e6, requests: 3210),
            Model(name: "openai/gpt-5-mini", spend: 9.6, tokens: 14.1e6, requests: 5120),
            Model(name: "google/gemini-2.5-flash", spend: 4.1, tokens: 9.4e6, requests: 2240),
            Model(name: "deepseek/deepseek-chat", spend: 1.8, tokens: 5.2e6, requests: 990),
            Model(name: "meta-llama/llama-3.3-70b-instruct", spend: 0.6, tokens: 1.9e6, requests: 410),
        ]
        plugin.key = KeyStatus(label: "sk-or-v1-a91…3f2", today: 2.84, week: 11.37, month: 48.90, total: 312.55,
                               limit: Limit(spend: 48.90, max: 100, resetsAt: Calendar.current.date(byAdding: .day, value: 9, to: Date()), interval: "monthly"),
                               freeTier: false, freeRequests: nil)
        plugin.credits = Credits(total: 150, used: 118.42)
        plugin.lastSuccess = Date()
        plugin.activityFetched = Date()
    }

    // MARK: Stored numbers

    /// One UTC day of the account's activity.
    struct Day: Codable, Equatable {
        var spend: Double
        var tokens: Double
        var requests: Double
    }

    /// A model's totals over the last 30 days.
    struct Model: Codable, Equatable {
        var name: String
        var spend: Double
        var tokens: Double
        var requests: Double
    }

    /// The limit that stops this key first: a budget layer or the key's own limit.
    struct Limit: Codable, Equatable {
        var spend: Double
        var max: Double
        var resetsAt: Date?
        /// `daily`, `weekly`, `monthly`, or nil for a lifetime limit.
        var interval: String?
    }

    /// What `/key` says about the API key.
    struct KeyStatus: Codable, Equatable {
        var label: String
        var today: Double
        var week: Double
        var month: Double
        var total: Double
        var limit: Limit?
        var freeTier: Bool
        /// Free-model requests today: used of the daily allowance.
        var freeRequests: FreeRequests?
    }

    struct FreeRequests: Codable, Equatable {
        var used: Int
        var limit: Int
    }

    struct Credits: Codable, Equatable {
        var total: Double
        var used: Double
        var remaining: Double { total - used }
    }

    enum Measure: String, CaseIterable {
        case spend = "Spend", tokens = "Tokens", requests = "Requests"
    }

    enum MenuBarShows: String, CaseIterable {
        case today = "Today", credits = "Credits", limit = "Limit"
    }

    @Stored("key") var key: KeyStatus? = nil
    @Stored("credits") var credits: Credits? = nil
    @Stored("days") var days: [String: Day] = [:]
    @Stored("models") var models: [Model] = []
    @Stored("activityFetched") var activityFetched: Date? = nil
    @Stored("lastSuccess") var lastSuccess: Date? = nil
    @Stored("measure") var measure = Measure.spend.rawValue
    @Stored("menuBarShows") var menuBarShows = MenuBarShows.today.rawValue
    @Stored("notifyLimit") var notifyLimit = true
    @Stored("notifyLowCredits") var notifyLowCredits = true
    @Stored("lowCredits") var lowCredits = 5.0
    /// The limit threshold last announced, by window, so each is said once.
    @Stored("notified") var notified: [String: Double] = [:]
    /// Whether "credits low" has been said since the balance last went above the line.
    @Stored("warnedLow") var warnedLow = false
    /// The management key's last four characters, so another account's activity starts fresh.
    @Stored("account") var account = ""

    var problem: String?
    /// Whether any key is set, so the panel asks for one.
    var connected = false
    var hasManagementKey = false
    /// Why the management key's numbers are missing, kept apart from the API key's problem.
    var managementProblem: String?
    var activityFailed: Date?
    var lastAttempt: Date?

    // MARK: - Fetching

    func refresh() async throws {
        lastAttempt = Date()
        let apiKey = try await Self.trimmedSecret("OPENROUTER_API_KEY")
        let managementKey = try await Self.trimmedSecret("OPENROUTER_MANAGEMENT_KEY")
        connected = apiKey != nil || managementKey != nil
        hasManagementKey = managementKey != nil
        guard connected else {
            problem = nil
            managementProblem = nil
            return
        }
        var failure: String?
        if let apiKey {
            do {
                key = try await fetchKey(apiKey)
            } catch {
                failure = "\(error)"
            }
        } else {
            key = nil
        }
        if let managementKey {
            let fingerprint = String(managementKey.suffix(4))
            if !account.isEmpty, account != fingerprint {
                days = [:]; models = []; credits = nil; activityFetched = nil; activityFailed = nil; warnedLow = false
            }
            if account != fingerprint { account = fingerprint }
            do {
                credits = try await fetchCredits(managementKey)
                managementProblem = nil
                // Activity covers completed days only, so once an hour is plenty;
                // a failure waits ten minutes before the next try.
                if activityFetched.map({ Date().timeIntervalSince($0) > 3600 }) ?? true,
                   activityFailed.map({ Date().timeIntervalSince($0) > 600 }) ?? true {
                    do {
                        let activity = try await fetchActivity(managementKey)
                        days = activity.days
                        models = activity.models
                        activityFetched = Date()
                        activityFailed = nil
                    } catch {
                        activityFailed = Date()
                        managementProblem = "\(error)"
                    }
                }
            } catch {
                managementProblem = "\(error)"
                if apiKey == nil { failure = "\(error)" }
            }
        } else {
            credits = nil
            managementProblem = nil
        }
        problem = failure
        if failure == nil { lastSuccess = Date() }
        announce()
    }

    /// A refresh unless one started less than `maxAge` ago: the palette view
    /// asks on every keystroke.
    func refresh(maxAge: TimeInterval) async throws {
        if let at = lastAttempt, Date().timeIntervalSince(at) < (problem == nil ? maxAge : max(maxAge, 30)) { return }
        try await refresh()
    }

    static func trimmedSecret(_ name: String) async throws -> String? {
        guard let value = try await Stackbar.secret(name)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private func get(_ path: String, key: String, secret: String) async throws -> Data {
        let response = try await Stackbar.http(HTTPRequest(url: Self.api + path, headers: ["Authorization": "Bearer \(key)", "Accept": "application/json"], timeout: 15))
        switch response.status {
        case 200..<300: return response.body
        case 401: throw HostError("OpenRouter refused the key. Check \(secret).")
        case 403: throw HostError("\(secret) can't read \(path). It needs a management key, made under Settings → Management Keys.")
        case 429: throw HostError("OpenRouter is rate limiting; trying again shortly.")
        default: throw HostError("OpenRouter answered \(response.status) for \(path).")
        }
    }

    private func fetchKey(_ apiKey: String) async throws -> KeyStatus {
        try Self.parseKey(try await get("/key", key: apiKey, secret: "OPENROUTER_API_KEY"))
    }

    private func fetchCredits(_ managementKey: String) async throws -> Credits {
        let reply = try JSONDecoder().decode(CreditsResponse.self, from: try await get("/credits", key: managementKey, secret: "OPENROUTER_MANAGEMENT_KEY"))
        return Credits(total: reply.data.total_credits ?? 0, used: reply.data.total_usage ?? 0)
    }

    private func fetchActivity(_ managementKey: String) async throws -> (days: [String: Day], models: [Model]) {
        try Self.parseActivity(try await get("/activity", key: managementKey, secret: "OPENROUTER_MANAGEMENT_KEY"))
    }

    /// `/key`'s reply. The limit shown is the budget that blocks first, or the
    /// key's own limit when no budget layer applies.
    static func parseKey(_ body: Data) throws -> KeyStatus {
        let data = try JSONDecoder().decode(KeyResponse.self, from: body).data
        var limit: Limit?
        if let budget = data.effective_budget, let max = budget.limit_usd, max > 0 {
            limit = Limit(spend: budget.spend_usd ?? 0, max: max, resetsAt: budget.resets_at.flatMap(parseDate), interval: budget.reset_interval)
        } else if let max = data.limit, max > 0 {
            let spend = data.limit_remaining.map { max - $0 } ?? data.usage ?? 0
            limit = Limit(spend: Swift.max(0, spend), max: max, resetsAt: nil, interval: data.limit_reset)
        }
        let free = data.free_model_daily_requests.flatMap { requests -> FreeRequests? in
            guard let limit = requests.limit, limit > 0 else { return nil }
            return FreeRequests(used: requests.used ?? 0, limit: limit)
        }
        return KeyStatus(label: data.label ?? "API key", today: data.usage_daily ?? 0, week: data.usage_weekly ?? 0, month: data.usage_monthly ?? 0,
                         total: data.usage ?? 0, limit: limit, freeTier: data.is_free_tier ?? false, freeRequests: free)
    }

    /// `/activity`'s rows, one per day, model and endpoint, summed by day and by model.
    static func parseActivity(_ body: Data) throws -> (days: [String: Day], models: [Model]) {
        let rows = try JSONDecoder().decode(ActivityResponse.self, from: body).data
        var days: [String: Day] = [:]
        var byModel: [String: Model] = [:]
        for row in rows {
            let spend = row.usage ?? 0
            let tokens = (row.prompt_tokens ?? 0) + (row.completion_tokens ?? 0)
            let requests = row.requests ?? 0
            var day = days[row.date] ?? Day(spend: 0, tokens: 0, requests: 0)
            day.spend += spend; day.tokens += tokens; day.requests += requests
            days[row.date] = day
            let name = row.model ?? "unknown"
            var model = byModel[name] ?? Model(name: name, spend: 0, tokens: 0, requests: 0)
            model.spend += spend; model.tokens += tokens; model.requests += requests
            byModel[name] = model
        }
        let models = byModel.values.filter { $0.spend > 0 || $0.tokens > 0 }.sorted { ($0.spend, $0.tokens, $1.name) > ($1.spend, $1.tokens, $0.name) }
        return (days, models)
    }

    /// Says once when the limit passes 90% and 100% in its window, and once
    /// when credits drop below the chosen line.
    private func announce() {
        if notifyLimit, let limit = key?.limit {
            let used = limit.spend / limit.max * 100
            let window = Self.window(limit)
            for threshold in [100.0, 90.0] where used >= threshold {
                if (notified[window] ?? 0) < threshold {
                    notified = [window: threshold]
                    Stackbar.notify(threshold >= 100 ? "OpenRouter limit reached" : "OpenRouter limit at \(Int(used))%",
                                    body: "\(Self.money(limit.spend)) of \(Self.money(limit.max))" + (limit.resetsAt.map { ", resets \(Self.relative($0))" } ?? ""))
                }
                break
            }
        }
        if let credits {
            if credits.remaining >= lowCredits {
                if warnedLow { warnedLow = false }
            } else if notifyLowCredits, !warnedLow {
                warnedLow = true
                Stackbar.notify("OpenRouter credits low", body: "\(Self.money(credits.remaining)) left of \(Self.money(credits.total)) bought.")
            }
        }
    }

    // MARK: - Surfaces

    let theme = Theme.indigo

    var lowOnCredits: Bool { credits.map { $0.remaining < lowCredits } ?? false }

    /// The share of the limit used, 0–100+.
    var limitUsed: Double? { key?.limit.map { $0.spend / $0.max * 100 } }

    var menuBar: ViewContent {
        if !connected || (key == nil && credits == nil) {
            Label("", symbol: "point.3.connected.trianglepath.dotted").role(.secondary)
        } else {
            Label(menuBarText, symbol: lowOnCredits || (limitUsed ?? 0) >= 90 ? "exclamationmark.triangle.fill" : "point.3.connected.trianglepath.dotted")
                .role(lowOnCredits || (limitUsed ?? 0) >= 90 ? .critical : (limitUsed ?? 0) >= 75 ? .warning : .primary)
        }
    }

    var menuBarText: String {
        switch MenuBarShows(rawValue: menuBarShows) ?? .today {
        case .today: return Self.money(todaySpend)
        case .credits: return credits.map { Self.money($0.remaining) } ?? Self.money(todaySpend)
        case .limit: return limitUsed.map { "\(Int($0.rounded()))%" } ?? Self.money(todaySpend)
        }
    }

    /// Today from the key; without one, yesterday is the newest day activity has.
    var todaySpend: Double { key?.today ?? 0 }

    var panel: ViewContent {
        VStack(spacing: Space.m) {
            if !connected {
                EmptyState("Connect OpenRouter", symbol: "key.fill",
                           message: "Enter an OpenRouter key as OPENROUTER_API_KEY for today's spend and its limit. Add a management key as OPENROUTER_MANAGEMENT_KEY for your credits, daily history and models.",
                           theme: theme) {
                    ActionButton("Get a Key", symbol: "arrow.up.right.square", theme: theme, prominent: true) { Stackbar.open("https://openrouter.ai/settings/keys") }
                }
            } else if key == nil && credits == nil, let message = problem ?? managementProblem {
                EmptyState("Can't reach OpenRouter", symbol: "exclamationmark.triangle", message: message, theme: .warning) {
                    ActionButton("Try Again", symbol: "arrow.clockwise", theme: theme, prominent: true) { try await self.refresh() }
                }
            } else if key == nil && credits == nil {
                loading
            } else {
                header
                if let problem { Banner("Showing numbers from \(lastSuccess.map(Self.relative) ?? "earlier"). \(problem)") }
                tiles
                creditsCard
                limitCard
                trendCard
                modelsCard
            }
        }
        .frame(fillWidth: true)
    }

    @ViewBuilder var header: ViewContent {
        PanelHeader("\(Self.money(todaySpend)) today",
                    subtitle: (credits.map { "\(Self.money($0.remaining)) credits left · " } ?? "") + "updated \(lastSuccess.map(Self.relative) ?? "never")",
                    symbol: "point.3.connected.trianglepath.dotted", theme: theme) {
            IconButton("arrow.up.right.square", label: "Open Activity", theme: theme) { Stackbar.open("https://openrouter.ai/activity") }
        }
    }

    @ViewBuilder var tiles: ViewContent {
        if let key {
            HeroCard(theme: theme, look: .glow, spacing: Space.s) {
                HStack(spacing: Space.l) {
                    HeroStat("Today", value: Self.money(key.today), theme: theme, live: key.today > 0)
                    HeroStat("This week", value: Self.money(key.week), theme: theme, symbol: "calendar")
                    HeroStat("This month", value: Self.money(key.month), theme: theme, symbol: "chart.bar.fill")
                    Spacer()
                }
                Text("\(key.label) · \(Self.money(key.total)) all time · UTC days").role(.secondary).typography(.captionNumber)
            }
        } else {
            let week = total(1...7), month = total(1...30)
            HeroCard(theme: theme, look: .glow, spacing: Space.s) {
                HStack(spacing: Space.l) {
                    HeroStat("Yesterday", value: Self.money(total(1...1).spend), theme: theme)
                    HeroStat("7 days", value: Self.money(week.spend), theme: theme, symbol: "calendar")
                    HeroStat("30 days", value: Self.money(month.spend), theme: theme, symbol: "chart.bar.fill")
                    Spacer()
                }
                Text("Add OPENROUTER_API_KEY to see today as it happens.").role(.secondary).typography(.caption)
            }
        }
    }

    @ViewBuilder var creditsCard: ViewContent {
        if let credits, credits.total > 0 {
            Card(spacing: Space.xs) {
                Meter("Credits", reading: "\(Self.money(credits.remaining)) left of \(Self.money(credits.total))", value: min(max(credits.used / credits.total, 0), 1),
                      theme: lowOnCredits ? .critical : credits.used / credits.total >= 0.75 ? .warning : theme)
                if lowOnCredits {
                    HStack(spacing: Space.s) {
                        Text("Below \(Self.money(lowCredits)).").role(.warning).typography(.caption)
                        Spacer()
                        ActionButton("Add Credits", symbol: "plus.circle", theme: theme) { Stackbar.open("https://openrouter.ai/settings/credits") }
                    }
                }
            }
        }
    }

    @ViewBuilder var limitCard: ViewContent {
        if let key, let limit = key.limit {
            let used = limit.spend / limit.max
            Card(spacing: Space.xs) {
                Meter(Self.limitTitle(limit), reading: "\(Self.money(limit.spend)) of \(Self.money(limit.max))", value: min(used, 1),
                      theme: used >= 0.9 ? .critical : used >= 0.75 ? .warning : theme)
                if let reset = limit.resetsAt {
                    Text("Resets \(Self.relative(reset))").role(.secondary).typography(.caption)
                }
            }
        }
        if let free = key?.freeRequests, key?.freeTier == true || free.used > 0 {
            Card(spacing: Space.xs) {
                Meter("Free model requests today", reading: "\(free.used) of \(free.limit)", value: min(Double(free.used) / Double(free.limit), 1),
                      theme: free.used >= free.limit ? .critical : theme)
            }
        }
    }

    @ViewBuilder var trendCard: ViewContent {
        if !days.isEmpty {
            let measure = Measure(rawValue: measure) ?? .spend
            Card(spacing: Space.s) {
                HStack(spacing: Space.s) {
                    CardTitle("Last 30 days")
                    Spacer()
                    Picker("Show", options: Measure.allCases.map(\.rawValue), selection: measure.rawValue, style: .segmented) { self.measure = $0 }
                        .frame(width: 210)
                }
                Chart(values: series(30, measure: measure), kind: .area, labels: dayLabels(30), unit: measure == .spend ? "$" : nil, highlight: 29)
                    .foreground(theme.solidPaint)
            }
        } else if connected && !hasManagementKey {
            Text("Add a management key as OPENROUTER_MANAGEMENT_KEY for your credits, a month of daily spend and your top models.")
                .role(.secondary).typography(.caption)
        } else if let managementProblem {
            Banner(managementProblem)
        }
    }

    @ViewBuilder var modelsCard: ViewContent {
        if !models.isEmpty {
            Card("Models", detail: "last 30 days, by spend") {
                Chart(values: modelSlices.map(\.value), kind: .donut, labels: modelSlices.map(\.name), unit: "$")
            }
        }
    }

    @ViewBuilder var loading: ViewContent {
        PanelHeader("Checking…", subtitle: "Fetching your usage from OpenRouter", symbol: "point.3.connected.trianglepath.dotted", theme: theme)
        HStack(spacing: Space.s) {
            ForEach(["Today", "This week", "This month"]) { name in
                StatTile(name, value: "–", theme: .neutral)
            }
        }
    }

    var widget: ViewContent {
        if !connected || (key == nil && credits == nil) {
            VStack(alignment: .center, spacing: Space.xs) {
                IconTile("point.3.connected.trianglepath.dotted", theme: theme)
                Text("Not connected").role(.secondary).typography(.caption)
            }
            .frame(fillWidth: true, fillHeight: true)
        } else {
            VStack(spacing: Space.s) {
                HStack(spacing: Space.m) {
                    Metric(Self.money(todaySpend), caption: key.map { "today · \(Self.money($0.month)) this month" } ?? "today", type: .metric)
                    Spacer()
                    if !days.isEmpty {
                        Chart(values: series(14, measure: .spend), kind: .area).foreground(theme.solidPaint).frame(width: 120, height: 48)
                    }
                }
                if let credits, credits.total > 0 {
                    Meter("Credits", reading: "\(Self.money(credits.remaining)) left", value: min(max(credits.used / credits.total, 0), 1), theme: lowOnCredits ? .critical : theme)
                } else if let limit = key?.limit {
                    Meter(Self.limitTitle(limit), reading: "\(Int((limit.spend / limit.max * 100).rounded()))%", value: min(limit.spend / limit.max, 1),
                          theme: limit.spend / limit.max >= 0.9 ? .critical : theme)
                }
            }
            .frame(fillWidth: true, fillHeight: true)
        }
    }

    var settings: ViewContent {
        Section("Account") {
            LabeledContent("API key", value: key?.label ?? "Not set: enter OPENROUTER_API_KEY")
            LabeledContent("Management key", value: hasManagementKey ? "Set" : "Not set (optional): OPENROUTER_MANAGEMENT_KEY")
            LabeledContent("Last update", value: lastSuccess.map(Self.relative) ?? "Never")
            if let problem { Text(problem).style(.caption).role(.warning) }
            if let managementProblem { Text(managementProblem).style(.caption).role(.warning) }
        }
        Section("Menu bar") {
            Picker("Shows", options: MenuBarShows.allCases.map(\.rawValue), selection: menuBarShows, style: .segmented) { self.menuBarShows = $0 }
        }
        Section("Notifications") {
            Toggle("Tell me at 90% and 100% of the key's limit", isOn: notifyLimit) { self.notifyLimit = $0 }
            Toggle("Tell me when credits run low", isOn: notifyLowCredits) { self.notifyLowCredits = $0 }
            Slider("Low below \(Self.money(lowCredits, cents: false))", value: lowCredits, in: 1...100, step: 1, key: "lowCredits") { self.lowCredits = $0 }
        }
    }

    // MARK: Commands

    var commands: [Command] {
        Command("spend", title: "OpenRouter Spend", subtitle: "Today, this week and month, credits and top models", symbol: "point.3.connected.trianglepath.dotted",
                keywords: ["openrouter", "llm", "credits", "spend", "cost", "tokens"])
            .view(search: { _ in try? await self.refresh(maxAge: 30) }) { _ in
                if !self.connected {
                    ContentUnavailableView("Connect OpenRouter", symbol: "key.fill", message: "Set OPENROUTER_API_KEY in Stackbar's Settings, and OPENROUTER_MANAGEMENT_KEY for credits and models.")
                } else if self.key == nil && self.credits == nil, let problem = self.problem ?? self.managementProblem {
                    ContentUnavailableView("Can't reach OpenRouter", symbol: "exclamationmark.triangle", message: problem)
                } else {
                    List {
                        if let problem = self.problem {
                            Row("Showing numbers from \(self.lastSuccess.map(Self.relative) ?? "earlier")", subtitle: problem, symbol: "exclamationmark.triangle", key: "spend-stale")
                        }
                        if let key = self.key {
                            self.spendRow("Today", key.today, key: "today")
                            self.spendRow("This week", key.week, key: "week")
                            self.spendRow("This month", key.month, key: "month")
                        }
                        if let credits = self.credits {
                            Row("Credits", subtitle: "\(Self.money(credits.remaining)) left of \(Self.money(credits.total))", symbol: "creditcard", key: "spend-credits")
                                .badge(Self.money(credits.remaining), role: self.lowOnCredits ? .critical : .secondary)
                                .action("Copy Summary") { Stackbar.copy(self.summaryText) }
                        }
                        if let limit = self.key?.limit {
                            Row(Self.limitTitle(limit), subtitle: "\(Self.money(limit.spend)) of \(Self.money(limit.max))" + (limit.resetsAt.map { ", resets \(Self.relative($0))" } ?? ""),
                                symbol: "gauge.with.dots.needle.67percent", key: "spend-limit")
                                .badge("\(Int((limit.spend / limit.max * 100).rounded()))%", role: (self.limitUsed ?? 0) >= 90 ? .critical : (self.limitUsed ?? 0) >= 75 ? .warning : .secondary)
                                .action("Copy Summary") { Stackbar.copy(self.summaryText) }
                        }
                        ForEach(Array(self.models.prefix(5))) { model in
                            Row(Self.shortName(model.name), subtitle: "\(Self.compact(model.tokens)) tokens · 30 days", symbol: "cpu", key: "spend-model-\(model.name)")
                                .badge(Self.money(model.spend))
                                .action("Copy Summary") { Stackbar.copy(self.summaryText) }
                        }
                    }
                }
            }
    }

    func spendRow(_ name: String, _ spend: Double, key: String) -> Row {
        Row(name, subtitle: "UTC", symbol: "chart.bar", key: "spend-" + key)
            .badge(Self.money(spend))
            .action("Copy Summary") { Stackbar.copy(self.summaryText) }
    }

    var tools: [AgentTool] {
        AgentTool("usage_summary", description: "OpenRouter spend today, this week and this month, the credit balance, the key's limit and the top models") { _ in
            self.summaryText
        }
    }

    // MARK: - Numbers

    /// Totals over UTC days ago, 1 being yesterday (activity has no today).
    func total(_ ago: ClosedRange<Int>) -> Day {
        let stored = days
        return ago.reduce(into: Day(spend: 0, tokens: 0, requests: 0)) { sum, offset in
            let day = stored[Self.day(-offset)] ?? Day(spend: 0, tokens: 0, requests: 0)
            sum.spend += day.spend; sum.tokens += day.tokens; sum.requests += day.requests
        }
    }

    /// The last `count` completed UTC days, oldest first.
    func series(_ count: Int, measure: Measure) -> [Double] {
        let stored = days
        return (1...count).reversed().map { offset in
            let day = stored[Self.day(-offset)]
            switch measure {
            case .spend: return day?.spend ?? 0
            case .tokens: return day?.tokens ?? 0
            case .requests: return day?.requests ?? 0
            }
        }
    }

    func dayLabels(_ count: Int) -> [String] {
        (1...count).reversed().enumerated().map { index, offset in
            (count - 1 - index) % 7 == 0 ? Self.labels.string(from: Date().addingTimeInterval(Double(-offset) * 86400)) : ""
        }
    }

    /// The top five models and the rest as "Other", by spend.
    var modelSlices: [(name: String, value: Double)] {
        let sorted = models.map { (name: Self.shortName($0.name), value: $0.spend) }.sorted { $0.value > $1.value }
        let rest = sorted.dropFirst(5).reduce(0) { $0 + $1.value }
        return Array(sorted.prefix(5)) + (rest > 0 ? [(name: "Other", value: rest)] : [])
    }

    var summaryText: String {
        guard connected else { return "OpenRouter is not connected: OPENROUTER_API_KEY is not set." }
        var lines: [String] = []
        if let key {
            lines.append("Today (UTC): \(Self.money(key.today))")
            lines.append("This week: \(Self.money(key.week))")
            lines.append("This month: \(Self.money(key.month))")
            if let limit = key.limit {
                lines.append("\(Self.limitTitle(limit)): \(Self.money(limit.spend)) of \(Self.money(limit.max))" + (limit.resetsAt.map { ", resets \(Self.relative($0))" } ?? ""))
            }
        }
        if let credits { lines.append("Credits: \(Self.money(credits.remaining)) left of \(Self.money(credits.total))") }
        if !days.isEmpty { lines.append("Last 30 days: \(Self.money(total(1...30).spend)), \(Self.compact(total(1...30).tokens)) tokens") }
        for model in models.prefix(5) {
            lines.append("\(model.name): \(Self.money(model.spend)), \(Self.compact(model.tokens)) tokens")
        }
        if let problem { lines.append("Problem: \(problem)") }
        if let managementProblem { lines.append("Management key: \(managementProblem)") }
        return lines.joined(separator: "\n")
    }

    // MARK: - Formatting

    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    static let labels: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    /// The UTC day `offset` days from today, as OpenRouter writes it.
    static func day(_ offset: Int) -> String {
        day(of: utc.date(byAdding: .day, value: offset, to: Date()) ?? Date())
    }

    static func day(of date: Date) -> String {
        let parts = utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Which window of the limit we are in, so its 90% and 100% are said once per window.
    static func window(_ limit: Limit, now: Date = Date()) -> String {
        if let reset = limit.resetsAt { return (limit.interval ?? "") + "|" + day(of: reset) }
        let today = day(of: now)
        switch limit.interval {
        case "daily": return "daily|" + today
        case "weekly":
            var monday = utc
            monday.firstWeekday = 2
            return "weekly|" + day(of: monday.dateInterval(of: .weekOfYear, for: now)?.start ?? now)
        case "monthly": return "monthly|" + today.prefix(7)
        default: return "lifetime"
        }
    }

    static func limitTitle(_ limit: Limit) -> String {
        switch limit.interval {
        case "daily": "Daily limit"
        case "weekly": "Weekly limit"
        case "monthly": "Monthly limit"
        default: "Limit"
        }
    }

    static func compact(_ value: Double) -> String {
        for (limit, suffix) in [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")] where abs(value) >= limit {
            let scaled = value / limit
            return (scaled >= 100 ? String(format: "%.0f", scaled) : String(format: "%.1f", scaled)) + suffix
        }
        return String(format: "%.0f", value)
    }

    static func money(_ value: Double, cents: Bool = true) -> String {
        value >= 1000 ? "$" + compact(value) : String(format: cents ? "$%.2f" : "$%.0f", value)
    }

    static func relative(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        let minutes = Int((abs(seconds) / 60).rounded())
        if minutes < 1 { return "just now" }
        let amount = minutes < 60 ? "\(minutes) min" : minutes < 48 * 60 ? "\(minutes / 60) h" : "\(minutes / 1440) days"
        return seconds > 0 ? "in \(amount)" : "\(amount) ago"
    }

    static func parseDate(_ text: String) -> Date? {
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return full.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// `anthropic/claude-sonnet-4.5` reads as `claude-sonnet-4.5`.
    static func shortName(_ name: String) -> String {
        name.split(separator: "/").last.map(String.init) ?? name
    }

    // MARK: - OpenRouter's JSON

    struct KeyResponse: Decodable {
        struct Budget: Decodable {
            var limit_usd: Double?
            var spend_usd: Double?
            var reset_interval: String?
            var resets_at: String?
        }
        struct Free: Decodable {
            var used: Int?
            var limit: Int?
        }
        struct Data: Decodable {
            var label: String?
            var limit: Double?
            var limit_remaining: Double?
            var limit_reset: String?
            var usage: Double?
            var usage_daily: Double?
            var usage_weekly: Double?
            var usage_monthly: Double?
            var is_free_tier: Bool?
            var effective_budget: Budget?
            var free_model_daily_requests: Free?
        }
        var data: Data
    }

    struct CreditsResponse: Decodable {
        struct Data: Decodable {
            var total_credits: Double?
            var total_usage: Double?
        }
        var data: Data
    }

    struct ActivityResponse: Decodable {
        struct Item: Decodable {
            var date: String
            var model: String?
            var usage: Double?
            var requests: Double?
            var prompt_tokens: Double?
            var completion_tokens: Double?
        }
        var data: [Item]
    }
}
