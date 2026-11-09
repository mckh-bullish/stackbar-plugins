import StackbarKit
import Foundation

/// Tokens and spend from your own LiteLLM proxy: today, the last week and
/// month as tiles, half a year of activity as a heatmap, a trend you can
/// switch between a week, a month and everything, and the model mix.
///
/// Nothing is contacted until you enter the proxy's URL as
/// LITELLM_PROXY_URL, and the plugin may reach that host and no other. The
/// key is LITELLM_API_KEY, kept in the Keychain. The last good numbers stay
/// on screen while the proxy can't be reached.
@main
final class LiteLLM: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.litellm",
        name: "LiteLLM",
        version: "1.6.0",
        summary: "Tokens, spend, budget and model mix from your LiteLLM proxy, with charts.",
        surfaces: [.menuBar, .panel, .window, .widget, .settings],
        triggers: [.launch, .minutes(2), .wake],
        capabilities: [.userServer(secret: "LITELLM_PROXY_URL"), .secret(name: "LITELLM_API_KEY")],
        minimumStackbar: "0.17.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Monitoring/LiteLLM",
        accent: .pink,
        symbol: "sparkles"
    )

    // MARK: Previews

    static let previews: [PreviewScene<LiteLLM>] = [
        PreviewScene("hero", "Spend, tokens and budget for your LLM proxy") { plugin in sample(plugin) },
        PreviewScene("dashboard", "Half a year of usage, by model", surface: .window) { plugin in sample(plugin) },
        PreviewScene("widget", "Today's spend on the desktop", surface: .widget) { plugin in sample(plugin) },
    ]

    /// Half a year of a small team's usage: weekdays busy, weekends quiet,
    /// growing slowly.
    static func sample(_ plugin: LiteLLM) {
        plugin.proxy = "https://llm.example.com"
        var days: [String: Day] = [:]
        for offset in -179...0 {
            let weekday = Calendar.current.component(.weekday, from: Date().addingTimeInterval(Double(offset) * 86400))
            let weekend = weekday == 1 || weekday == 7
            let growth = 1 + Double(offset + 180) / 180
            let wobble = 0.8 + 0.4 * abs(sin(Double(offset) * 1.7))
            let tokens = (weekend ? 0.6e6 : 3.2e6) * growth * wobble
            let requests = (tokens / 2600).rounded()
            days[day(offset)] = Day(tokens: tokens, spend: tokens / 1e6 * 4.1, requests: requests, failed: (requests * 0.012).rounded())
        }
        plugin.days = days
        plugin.models = [
            Model(name: "claude-sonnet", tokens: 212e6, spend: 868),
            Model(name: "gpt-5-mini", tokens: 140e6, spend: 214),
            Model(name: "claude-haiku", tokens: 96e6, spend: 118),
            Model(name: "text-embedding-3-small", tokens: 61e6, spend: 6),
            Model(name: "llama-3.3-70b", tokens: 22e6, spend: 19),
        ]
        plugin.budget = Budget(spend: 612, max: 1000, resetAt: Calendar.current.date(byAdding: .day, value: 12, to: Date()))
        // Today's mix splits today's totals, so the two always add up.
        let today = days[day(0)] ?? Day(tokens: 0, spend: 0)
        let mix: [(String, Double, Double)] = [("claude-sonnet", 0.46, 0.71), ("gpt-5-mini", 0.29, 0.2), ("claude-haiku", 0.17, 0.085), ("text-embedding-3-small", 0.08, 0.005)]
        plugin.todayDetail = Today(date: day(0), requests: 1490, failed: 17, promptTokens: 2.9e6, cacheReadTokens: 1.1e6, cacheSavings: 3.4,
                                   models: mix.map { Model(name: $0.0, tokens: today.tokens * $0.1, spend: today.spend * $0.2) })
        plugin.historyFetched = Date()
        plugin.lastSuccess = Date()
    }

    /// One day's totals, kept between runs for the heatmap and the trend.
    struct Day: Codable, Equatable {
        var tokens: Double
        var spend: Double
        var requests: Double = 0
        var failed: Double = 0
    }

    struct Model: Codable, Equatable {
        var name: String
        var tokens: Double
        var spend: Double
    }

    struct Budget: Codable, Equatable {
        var spend: Double
        var max: Double?
        var resetAt: Date?
    }

    enum Range: String, CaseIterable {
        case week = "Week", month = "Month", halfYear = "6M"
    }

    enum Measure: String, CaseIterable {
        case tokens = "Tokens", spend = "Spend"
    }

    enum MenuBarShows: String, CaseIterable {
        case spend = "Spend", tokens = "Tokens", budget = "Budget"
    }

    @Stored("days") var days: [String: Day] = [:]
    @Stored("models") var models: [Model] = []
    @Stored("budget") var budget: Budget? = nil
    @Stored("today") var todayDetail: Today? = nil
    @Stored("historyFetched") var historyFetched: Date? = nil
    @Stored("lastSuccess") var lastSuccess: Date? = nil
    @Stored("range") var range = Range.month.rawValue
    @Stored("measure") var measure = Measure.tokens.rawValue
    @Stored("menuBarShows") var menuBarShows = MenuBarShows.spend.rawValue
    @Stored("notifyBudget") var notifyBudget = true
    @Stored("notified") var notified: [String: Double] = [:]
    /// The proxy and user the stored numbers belong to, so another one starts its history fresh.
    @Stored("source") var source = ""

    /// Today's health, from the latest fetch.
    struct Today: Codable, Equatable {
        var date: String
        var requests: Double
        var failed: Double
        var promptTokens: Double
        var cacheReadTokens: Double
        var cacheSavings: Double
        /// What each model cost today, most expensive first.
        var models: [Model]? = nil
    }

    var problem: String?
    var proxy: String?
    /// When the last history fetch failed, to back off before trying again.
    var historyFailed: Date?
    /// Whether the last refresh found no key, so the panel asks for one.
    var needsKey = false
    /// When the last refresh started, so the palette's Spend view doesn't ask on every keystroke.
    var lastAttempt: Date?
    /// When `/key/info` last gave no budget, so it isn't asked on every refresh.
    var keyInfoMissed: Date?

    // MARK: - Fetching

    func refresh() async throws {
        lastAttempt = Date()
        guard let url = try await Stackbar.secret("LITELLM_PROXY_URL")?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else {
            proxy = nil
            problem = "Enter your proxy's URL as LITELLM_PROXY_URL."
            return
        }
        let base = url.hasSuffix("/") ? String(url.dropLast()) : url
        proxy = base
        guard let key = try await Stackbar.secret("LITELLM_API_KEY")?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            needsKey = true
            problem = "Enter a LiteLLM key as LITELLM_API_KEY."
            return
        }
        needsKey = false
        do {
            async let account = fetchBudget(base: base, key: key)
            async let month = fetchDays(base: base, key: key, from: Self.day(-30), to: Self.day(0))
            let (fetched, recent) = try await (account, month)
            // Another proxy or user has other numbers: its history starts over
            // rather than mixing in the old one's.
            let current = base + "|" + (fetched.userID ?? "")
            if !source.isEmpty, source != current { days = [:]; historyFetched = nil; historyFailed = nil; notified = [:]; todayDetail = nil }
            if source != current { source = current }
            budget = fetched.budget
            merge(recent.days)
            models = recent.models
            todayDetail = recent.today
            // The half-year history is a bonus: if it fails, the 30-day numbers
            // still count, and it waits half an hour before the next try.
            if historyFetched.map({ Date().timeIntervalSince($0) > 6 * 3600 }) ?? true,
               historyFailed.map({ Date().timeIntervalSince($0) > 30 * 60 }) ?? true {
                do {
                    let history = try await fetchDays(base: base, key: key, from: Self.day(-182), to: Self.day(-31))
                    merge(history.days)
                    historyFetched = Date()
                    historyFailed = nil
                } catch {
                    historyFailed = Date()
                }
            }
            lastSuccess = Date()
            problem = nil
            notifyAboutBudget()
        } catch {
            problem = "\(error)"
        }
    }

    /// A refresh unless one started less than `maxAge` ago. The Spend view asks
    /// on every keystroke, so it waits, and a failed proxy waits 30 s at least.
    func refresh(maxAge: TimeInterval) async throws {
        if let at = lastAttempt, Date().timeIntervalSince(at) < (problem == nil ? maxAge : max(maxAge, 30)) { return }
        try await refresh()
    }

    private func headers(_ key: String) -> [String: String] {
        ["Authorization": "Bearer \(key)", "Accept": "application/json"]
    }

    /// The user's budget and id. A key can carry its own budget (virtual and
    /// team keys often do) while its user has none, so that one is used then.
    private func fetchBudget(base: String, key: String) async throws -> (budget: Budget?, userID: String?) {
        let response = try await Stackbar.http(HTTPRequest(url: base + "/user/info", headers: headers(key), timeout: 15))
        try check(response, what: "/user/info")
        let reply = try JSONDecoder().decode(UserInfoResponse.self, from: response.body)
        var budget: Budget?
        if let info = reply.user_info {
            let max = info.max_budget?.value
            budget = Budget(spend: info.spend?.value ?? 0, max: max.flatMap { $0 > 0 ? $0 : nil }, resetAt: info.budget_reset_at.flatMap(Self.parseDate))
        }
        if budget?.max == nil, keyInfoMissed.map({ Date().timeIntervalSince($0) > 3600 }) ?? true {
            if let keyBudget = await fetchKeyBudget(base: base, key: key) {
                return (keyBudget, reply.user_id)
            }
            keyInfoMissed = Date()
        }
        return (budget, reply.user_id)
    }

    /// The key's own budget from `/key/info`. Any failure, or no budget, is nil.
    private func fetchKeyBudget(base: String, key: String) async -> Budget? {
        guard let response = try? await Stackbar.http(HTTPRequest(url: base + "/key/info", headers: headers(key), timeout: 15)),
              (200..<300).contains(response.status),
              let info = (try? JSONDecoder().decode(KeyInfo.self, from: response.body))?.info,
              let max = info.max_budget?.value, max > 0 else { return nil }
        return Budget(spend: info.spend?.value ?? 0, max: max, resetAt: info.budget_reset_at.flatMap(Self.parseDate))
    }

    struct Fetched {
        var days: [String: Day] = [:]
        var models: [Model] = []
        var today: Today?
    }

    /// `/user/daily/activity` for a span of days, page by page.
    private func fetchDays(base: String, key: String, from: String, to: String) async throws -> Fetched {
        var fetched = Fetched()
        var byModel: [String: Model] = [:]
        var page = 1
        while page <= 20 {
            let response = try await Stackbar.http(HTTPRequest(url: base + "/user/daily/activity?start_date=\(from)&end_date=\(to)&page=\(page)&page_size=100", headers: headers(key), timeout: 15))
            try check(response, what: "/user/daily/activity")
            let activity = try JSONDecoder().decode(ActivityResponse.self, from: response.body)
            for result in activity.results ?? [] {
                let metrics = result.metrics ?? Metrics()
                fetched.days[result.date] = Day(tokens: metrics.tokens, spend: metrics.spend?.value ?? 0, requests: metrics.requests, failed: metrics.failed_requests ?? 0)
                var dayModels: [String: Model] = [:]
                for (name, breakdown) in result.breakdown?.models ?? [:] {
                    let model = breakdown?.metrics ?? Metrics()
                    let short = Self.shortName(name)
                    for index in 0..<2 {
                        var total = (index == 0 ? byModel[short] : dayModels[short]) ?? Model(name: short, tokens: 0, spend: 0)
                        total.tokens += model.tokens
                        total.spend += model.spend?.value ?? 0
                        if index == 0 { byModel[short] = total } else { dayModels[short] = total }
                    }
                }
                if result.date == Self.day(0) {
                    fetched.today = Today(date: result.date, requests: metrics.requests, failed: metrics.failed_requests ?? 0,
                                          promptTokens: metrics.prompt_tokens ?? 0, cacheReadTokens: metrics.cache_read_input_tokens ?? 0,
                                          cacheSavings: metrics.prompt_caching_savings_spend ?? 0,
                                          models: Self.bySpend(dayModels.values))
                }
            }
            let pages = activity.metadata?.total_pages ?? 1
            guard activity.metadata?.has_more == true || page < pages else { break }
            page += 1
        }
        fetched.models = byModel.values.filter { $0.tokens > 0 || $0.spend > 0 }.sorted { $0.tokens > $1.tokens }
        return fetched
    }

    /// Models that were used, the most expensive first, then by tokens.
    static func bySpend(_ models: some Sequence<Model>) -> [Model] {
        models.filter { $0.tokens > 0 || $0.spend > 0 }
            .sorted { $0.spend != $1.spend ? $0.spend > $1.spend : $0.tokens > $1.tokens }
    }

    private func check(_ response: HTTPResponse, what: String) throws {
        switch response.status {
        case 200..<300: return
        case 401, 403: throw HostError("The proxy refused the key (\(response.status)). Check LITELLM_API_KEY.")
        case 404: throw HostError("The proxy has no \(what). Is LITELLM_PROXY_URL the proxy's base URL?")
        default: throw HostError("The proxy answered \(response.status) for \(what).")
        }
    }

    private func merge(_ fetched: [String: Day]) {
        var all = days
        for (date, day) in fetched { all[date] = day }
        let oldest = Self.day(-200)
        days = all.filter { $0.key >= oldest }
    }

    private func notifyAboutBudget() {
        guard notifyBudget, let budget, let max = budget.max else { return }
        let used = budget.spend / max * 100
        let today = Self.day(0)
        for threshold in [100.0, 90.0] where used >= threshold {
            guard (notified[today] ?? 0) < threshold else { return }
            notified = [today: threshold]
            Stackbar.notify(threshold >= 100 ? "LiteLLM budget used up" : "LiteLLM budget at \(Int(used))%",
                            body: "\(Self.money(budget.spend)) of \(Self.money(max))" + (budget.resetAt.map { ", resets \(Self.relative($0))" } ?? ""))
            return
        }
    }

    // MARK: - Surfaces

    let theme = Theme.pink

    var menuBar: ViewContent {
        if proxy == nil || (days.isEmpty && budget == nil) {
            Label("", symbol: "gauge.with.dots.needle.0percent").role(.secondary)
        } else {
            Label(menuBarText, symbol: budgetUsed.map { $0 >= 90 ? "exclamationmark.triangle.fill" : $0 >= 50 ? "gauge.with.dots.needle.50percent" : "gauge.with.dots.needle.33percent" } ?? "gauge.with.dots.needle.33percent")
                .role(budgetUsed.map { $0 >= 90 ? .critical : $0 >= 75 ? .warning : .primary } ?? .primary)
        }
    }

    var panel: ViewContent {
        VStack(spacing: Space.m) {
            if proxy == nil {
                EmptyState("Connect your LiteLLM proxy", symbol: "server.rack",
                           message: "Paste its URL as LITELLM_PROXY_URL and a key as LITELLM_API_KEY. Nothing is contacted until you do.", theme: theme)
            } else if needsKey && days.isEmpty {
                EmptyState("Add your LiteLLM key", symbol: "key.fill", message: "Enter a LiteLLM key as LITELLM_API_KEY. It stays in your Keychain.", theme: theme)
            } else if days.isEmpty, let problem {
                EmptyState("Can't reach the proxy", symbol: "exclamationmark.triangle", message: problem, theme: .warning) {
                    ActionButton("Try Again", symbol: "arrow.clockwise", theme: theme, prominent: true) { try await self.refresh() }
                }
            } else if days.isEmpty {
                loading
            } else {
                header
                staleBanner
                tiles
                budgetCard
                todayModelsCard
                trendCard
            }
        }
        .frame(fillWidth: true)
    }

    /// The full dashboard: the panel, then the half year, the model mix and today's request health.
    var window: ViewContent {
        VStack(spacing: Space.m) {
            if days.isEmpty {
                panel
            } else {
                header
                staleBanner
                tiles
                budgetCard
                todayModelsCard
                trendCard
                Card("Activity", detail: "\(activeDays(0...181)) active days in 6 months") {
                    Chart(values: series(days: 182, measure: .tokens), kind: .heatmap, labels: dayLabels(182, formatter: Self.longLabels), unit: " tokens")
                        .foreground(theme.solidPaint)
                }
                if !models.isEmpty {
                    Card("Models", detail: "last 30 days, by \(currentMeasure == .spend ? "spend" : "tokens")") {
                        Chart(values: modelSlices.map(\.value), kind: .donut, labels: modelSlices.map(\.name), unit: currentMeasure == .spend ? "$" : nil)
                    }
                }
                if let today = todayDetail, today.requests > 0 {
                    Card("Today's requests") {
                        HStack(spacing: Space.s) {
                            StatTile("Requests", value: Self.compact(today.requests), theme: theme)
                            StatTile("Succeeded", value: String(format: "%.1f%%", (today.requests - today.failed) / today.requests * 100),
                                     caption: today.failed > 0 ? "\(Self.compact(today.failed)) failed" : nil, theme: today.failed > 0 ? .warning : .success)
                            if today.promptTokens > 0 {
                                StatTile("From cache", value: "\(Int((today.cacheReadTokens / today.promptTokens * 100).rounded()))%",
                                         caption: today.cacheSavings > 0 ? "saved \(Self.money(today.cacheSavings))" : "of input", theme: theme)
                            }
                        }
                    }
                }
            }
        }
        .frame(fillWidth: true)
    }

    @ViewBuilder var header: ViewContent {
        let today = total(0...0)
        let title: String = switch MenuBarShows(rawValue: menuBarShows) ?? .spend {
        case .tokens: "\(Self.compact(today.tokens)) tokens today"
        case .budget: budgetUsed.map { "\(Int($0.rounded()))% of budget" } ?? "\(Self.money(today.spend)) today"
        case .spend: "\(Self.money(today.spend)) today"
        }
        let other = MenuBarShows(rawValue: menuBarShows) == .tokens ? Self.money(today.spend) : "\(Self.compact(today.tokens)) tokens"
        PanelHeader(title, subtitle: "\(other) · updated \(lastSuccess.map(Self.relative) ?? "never")",
                    symbol: "gauge.with.dots.needle.67percent", theme: theme) {
            IconButton("arrow.up.right.square", label: "Open Dashboard", theme: theme) { if let proxy = self.proxy { Stackbar.open(proxy + "/ui") } }
        }
    }

    @ViewBuilder var staleBanner: ViewContent {
        if let problem {
            Banner("Showing numbers from \(lastSuccess.map(Self.relative) ?? "earlier"). \(problem)")
        }
    }

    @ViewBuilder var tiles: ViewContent {
        let week = total(0...6), month = total(0...29)
        HeroCard(theme: theme, look: .glow, spacing: Space.s) {
            HStack(spacing: Space.l) {
                HeroStat("Today", value: Self.compact(total(0...0).tokens), theme: theme, live: total(0...0).tokens > 0)
                HeroStat("7 days", value: Self.compact(week.tokens), theme: theme, symbol: "calendar")
                HeroStat("30 days", value: Self.compact(month.tokens), theme: theme, symbol: "chart.bar.fill")
                Spacer()
            }
            Text("\(Self.money(total(0...0).spend)) today · \(Self.money(week.spend)) this week · ~\(Self.compact(month.tokens / Double(max(1, activeDays(0...29)))))/day").role(.secondary).typography(.captionNumber)
        }
    }

    @ViewBuilder var budgetCard: ViewContent {
        if let budget, let max = budget.max {
            let used = budget.spend / max
            Card(spacing: Space.xs) {
                Meter("Budget", reading: "\(Self.money(budget.spend)) of \(Self.money(max))", value: min(used, 1),
                      theme: used >= 0.9 ? .critical : used >= 0.75 ? .warning : theme)
                if let reset = budget.resetAt {
                    Text("Resets \(Self.relative(reset))").role(.secondary).typography(.caption)
                }
            }
        }
    }

    /// Today's models, the most expensive first. The models from the latest
    /// fetch only count while it is still today.
    var todayModels: [Model] {
        guard let today = todayDetail, today.date == Self.day(0) else { return [] }
        return today.models ?? []
    }

    /// What each model cost today, as bars against the day's total.
    @ViewBuilder var todayModelsCard: ViewContent {
        let models = todayModels
        if !models.isEmpty {
            let spend = models.reduce(0) { $0 + $1.spend }
            let top = models.prefix(5)
            let rest = models.dropFirst(5)
            Card("Today by model", detail: "\(Self.money(spend, cents: true)) across \(models.count) model\(models.count == 1 ? "" : "s")", spacing: Space.s) {
                ForEach(Array(top)) { model in
                    Meter(model.name, reading: "\(Self.money(model.spend, cents: true)) · \(Self.compact(model.tokens)) tokens",
                          value: spend > 0 ? model.spend / spend : 0, theme: theme)
                }
                if !rest.isEmpty {
                    let other = rest.reduce(Model(name: "", tokens: 0, spend: 0)) { Model(name: "", tokens: $0.tokens + $1.tokens, spend: $0.spend + $1.spend) }
                    Meter("\(rest.count) more", reading: "\(Self.money(other.spend, cents: true)) · \(Self.compact(other.tokens)) tokens",
                          value: spend > 0 ? other.spend / spend : 0, theme: .neutral)
                }
            }
        }
    }

    @ViewBuilder var trendCard: ViewContent {
        Card(spacing: Space.s) {
            HStack(spacing: Space.s) {
                Picker("Range", options: Range.allCases.map(\.rawValue), selection: range, style: .segmented) { self.range = $0 }
                Spacer()
                Picker("Show", options: Measure.allCases.map(\.rawValue), selection: measure, style: .segmented) { self.measure = $0 }
                    .frame(width: 130)
            }
            trendChart.foreground(theme.solidPaint)
        }
    }

    @ViewBuilder var loading: ViewContent {
        PanelHeader("Checking…", subtitle: "Fetching your usage from \(proxy ?? "the proxy")", symbol: "gauge.with.dots.needle.67percent", theme: theme)
        HStack(spacing: Space.s) {
            ForEach(["Today", "7 days", "30 days"]) { name in
                StatTile(name, value: "–", theme: .neutral)
            }
        }
        Rectangle().fill(.surface).frame(height: 160).clipShape(.roundedRectangle(cornerRadius: Radius.large))
    }

    @ViewBuilder var trendChart: ViewContent {
        let measure = currentMeasure
        let unit = measure == .tokens ? nil : "$"
        switch Range(rawValue: range) ?? .month {
        case .week:
            Chart(values: series(days: 7, measure: measure), kind: .bar, labels: dayLabels(7, formatter: Self.weekdayLabels), unit: unit, highlight: 6)
        case .month:
            Chart(values: series(days: 30, measure: measure), kind: .area, labels: sparseLabels(dayLabels(30, formatter: Self.monthDayLabels), every: 7), unit: unit, highlight: 29)
        case .halfYear:
            let weeks = weekly(measure: measure)
            Chart(values: weeks.values, kind: .area, labels: weeks.labels, unit: unit)
        }
    }

    var widget: ViewContent {
        if proxy == nil || days.isEmpty {
            VStack(alignment: .center, spacing: Space.xs) {
                IconTile("server.rack", theme: theme)
                Text("Not connected").role(.secondary).typography(.caption)
            }
            .frame(fillWidth: true, fillHeight: true)
        } else {
            VStack(spacing: Space.s) {
                HStack(spacing: Space.m) {
                    Metric(Self.money(total(0...0).spend), caption: "today · \(Self.compact(total(0...0).tokens)) tokens", type: .metric)
                    Spacer()
                    Chart(values: series(days: 14, measure: .tokens), kind: .area).foreground(theme.solidPaint).frame(width: 120, height: 48)
                }
                if let budget, let max = budget.max {
                    let used = budget.spend / max
                    Meter("Budget", reading: "\(Int((used * 100).rounded()))%", value: min(used, 1), theme: used >= 0.9 ? .critical : used >= 0.75 ? .warning : theme)
                }
            }
            .frame(fillWidth: true, fillHeight: true)
        }
    }

    var settings: ViewContent {
        Section("Proxy") {
            LabeledContent("URL", value: proxy ?? "Not set: enter LITELLM_PROXY_URL")
            LabeledContent("Last update", value: lastSuccess.map(Self.relative) ?? "Never")
            if let problem { Text(problem).style(.caption).role(.warning) }
        }
        Section("Menu bar") {
            Picker("Shows", options: MenuBarShows.allCases.map(\.rawValue), selection: menuBarShows, style: .segmented) { self.menuBarShows = $0 }
        }
        Section("Notifications") {
            Toggle("Tell me at 90% and 100% of the budget", isOn: notifyBudget) { self.notifyBudget = $0 }
        }
    }

    // MARK: Commands

    var commands: [Command] {
        Command("spend", title: "LiteLLM Spend", subtitle: "Today, 7 and 30 days, the budget, and what each model cost", symbol: "gauge.with.dots.needle.50percent", keywords: ["litellm", "llm", "tokens", "spend", "cost", "budget"])
            .view(search: { _ in try? await self.refresh(maxAge: 30) }) { _ in
                if self.proxy == nil {
                    ContentUnavailableView("Connect your LiteLLM proxy", symbol: "server.rack", message: "Set LITELLM_PROXY_URL and LITELLM_API_KEY in Stackbar's Settings.")
                } else if self.needsKey && self.days.isEmpty {
                    ContentUnavailableView("Add your LiteLLM key", symbol: "key.fill", message: "Set LITELLM_API_KEY in Stackbar's Settings.")
                } else if let problem = self.problem, self.days.isEmpty {
                    ContentUnavailableView("Can't reach the proxy", symbol: "exclamationmark.triangle", message: problem)
                } else {
                    List {
                        if let problem = self.problem {
                            Row("Showing numbers from \(self.lastSuccess.map(Self.relative) ?? "earlier")", subtitle: problem, symbol: "exclamationmark.triangle", key: "spend-stale")
                        }
                        self.spendRow("Today", 0...0)
                        self.spendRow("7 days", 0...6)
                        self.spendRow("30 days", 0...29)
                        if let budget = self.budget, let max = budget.max {
                            Row("Budget", subtitle: "\(Self.money(budget.spend, cents: true)) of \(Self.money(max))" + (budget.resetAt.map { ", resets \(Self.relative($0))" } ?? ""),
                                symbol: "gauge.with.dots.needle.67percent", key: "spend-budget")
                                .badge(self.budgetUsed.map { "\(Int($0))%" } ?? "", role: (self.budgetUsed ?? 0) >= 90 ? .critical : (self.budgetUsed ?? 0) >= 75 ? .warning : .secondary)
                                .action("Copy Summary") { Stackbar.copy(self.summaryText) }
                        }
                        ForEach(self.todayModels) { model in
                            Row(model.name, subtitle: "\(Self.compact(model.tokens)) tokens · today", symbol: "cpu", key: "spend-today-\(model.name)")
                                .badge(Self.money(model.spend, cents: true))
                                .action("Copy Summary") { Stackbar.copy(self.summaryText) }
                        }
                        ForEach(Array(self.models.prefix(5))) { model in
                            Row(model.name, subtitle: "\(Self.compact(model.tokens)) tokens · 30 days", symbol: "cpu", key: "spend-model-\(model.name)")
                                .badge(Self.money(model.spend, cents: true))
                                .action("Copy Summary") { Stackbar.copy(self.summaryText) }
                        }
                    }
                }
            }
    }

    func spendRow(_ name: String, _ range: ClosedRange<Int>) -> Row {
        let total = total(range)
        return Row(name, subtitle: "\(Self.compact(total.tokens)) tokens", symbol: "chart.bar", key: "spend-" + name)
            .badge(Self.money(total.spend, cents: true))
            .action("Copy Summary") { Stackbar.copy(self.summaryText) }
    }

    var tools: [AgentTool] {
        AgentTool("usage_summary", description: "LiteLLM tokens and spend for today, 7 and 30 days, the budget, today's cost per model and the top models over 30 days") { _ in
            self.summaryText
        }
    }

    // MARK: - Numbers

    var currentMeasure: Measure { Measure(rawValue: measure) ?? .tokens }

    var budgetUsed: Double? {
        guard let budget, let max = budget.max else { return nil }
        return budget.spend / max * 100
    }

    var menuBarText: String {
        switch MenuBarShows(rawValue: menuBarShows) ?? .spend {
        case .spend: return Self.money(total(0...0).spend, cents: true)
        case .tokens: return Self.compact(total(0...0).tokens)
        case .budget: return budgetUsed.map { "\(Int($0.rounded()))%" } ?? Self.money(total(0...0).spend, cents: true)
        }
    }

    /// Totals over days ago, 0 being today.
    func total(_ ago: ClosedRange<Int>) -> Day {
        // One read of the stored days: each read decodes the whole dictionary.
        let stored = days
        return ago.reduce(into: Day(tokens: 0, spend: 0)) { sum, offset in
            let day = stored[Self.day(-offset)] ?? Day(tokens: 0, spend: 0)
            sum.tokens += day.tokens
            sum.spend += day.spend
            sum.requests += day.requests
            sum.failed += day.failed
        }
    }

    func activeDays(_ ago: ClosedRange<Int>) -> Int {
        let stored = days
        return ago.filter { (stored[Self.day(-$0)]?.tokens ?? 0) > 0 }.count
    }

    /// The last `count` days, oldest first.
    func series(days count: Int, measure: Measure) -> [Double] {
        let stored = days
        return (0..<count).reversed().map { offset in
            let day = stored[Self.day(-offset)]
            return measure == .tokens ? day?.tokens ?? 0 : day?.spend ?? 0
        }
    }

    /// Kept rather than built per call: a window asks for about 200 labels a render.
    static let weekdayLabels = labelFormatter("EEE")
    static let monthDayLabels = labelFormatter("MMM d")
    static let longLabels = labelFormatter("EEE d MMM")

    static func labelFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    func dayLabels(_ count: Int, formatter: DateFormatter) -> [String] {
        (0..<count).reversed().map { formatter.string(from: Calendar.current.date(byAdding: .day, value: -$0, to: Date()) ?? Date()) }
    }

    /// Keeps every `every`th label, counted back from the last, and blanks the
    /// rest so a month's axis stays readable.
    func sparseLabels(_ labels: [String], every: Int) -> [String] {
        labels.enumerated().map { index, label in (labels.count - 1 - index) % every == 0 ? label : "" }
    }

    func weekly(measure: Measure) -> (values: [Double], labels: [String]) {
        let daily = series(days: 182, measure: measure)
        let names = dayLabels(182, formatter: Self.monthDayLabels)
        var values: [Double] = []
        var labels: [String] = []
        for start in stride(from: daily.count % 7, to: daily.count, by: 7) {
            values.append(daily[start..<min(start + 7, daily.count)].reduce(0, +))
            labels.append(values.count % 4 == 1 ? names[start] : "")
        }
        return (values, labels)
    }

    /// The top five models and the rest as "Other", by the chosen measure.
    var modelSlices: [(name: String, value: Double)] {
        let measure = currentMeasure
        let sorted = models.map { (name: $0.name, value: measure == .tokens ? $0.tokens : $0.spend) }.sorted { $0.value > $1.value }
        let rest = sorted.dropFirst(5).reduce(0) { $0 + $1.value }
        return Array(sorted.prefix(5)) + (rest > 0 ? [(name: "Other", value: rest)] : [])
    }

    var summaryText: String {
        guard proxy != nil else { return "LiteLLM is not connected: LITELLM_PROXY_URL is not set." }
        var lines = [
            "Today: \(Self.compact(total(0...0).tokens)) tokens, \(Self.money(total(0...0).spend, cents: true))",
            "7 days: \(Self.compact(total(0...6).tokens)) tokens, \(Self.money(total(0...6).spend, cents: true))",
            "30 days: \(Self.compact(total(0...29).tokens)) tokens, \(Self.money(total(0...29).spend, cents: true))",
        ]
        if let budget, let max = budget.max {
            lines.append("Budget: \(Self.money(budget.spend, cents: true)) of \(Self.money(max))" + (budget.resetAt.map { ", resets \(Self.relative($0))" } ?? ""))
        }
        for model in todayModels {
            lines.append("Today, \(model.name): \(Self.compact(model.tokens)) tokens, \(Self.money(model.spend, cents: true))")
        }
        for model in models.prefix(5) {
            lines.append("30 days, \(model.name): \(Self.compact(model.tokens)) tokens, \(Self.money(model.spend, cents: true))")
        }
        if let problem { lines.append("Problem: \(problem)") }
        return lines.joined(separator: "\n")
    }

    // MARK: - Formatting

    static func day(_ offset: Int) -> String {
        // Components rather than a DateFormatter: this runs hundreds of times a render.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Calendar.current.timeZone
        let date = calendar.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
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
        let amount = minutes < 1 ? "now" : minutes < 60 ? "\(minutes) min" : minutes < 48 * 60 ? "\(minutes / 60) h" : "\(minutes / 1440) days"
        if amount == "now" { return "just now" }
        return seconds > 0 ? "in \(amount)" : "\(amount) ago"
    }

    static func parseDate(_ text: String) -> Date? {
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        return full.date(from: text) ?? plain.date(from: text) ?? plain.date(from: text + "Z")
    }

    /// `anthropic/claude-sonnet-4` reads as `claude-sonnet-4`.
    static func shortName(_ name: String) -> String {
        name.split(separator: "/").last.map(String.init) ?? name
    }

    // MARK: - LiteLLM's JSON

    /// A number LiteLLM sends either as a number or as a string.
    struct Flexible: Decodable {
        var value: Double
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                value = number
            } else {
                value = Double(try container.decode(String.self)) ?? 0
            }
        }
    }

    struct UserInfoResponse: Decodable {
        struct Info: Decodable {
            var spend: Flexible?
            var max_budget: Flexible?
            var budget_reset_at: String?
        }
        var user_id: String?
        var user_info: Info?
    }

    /// `/key/info`: a key's own spend and budget, in the same fields as a user's.
    struct KeyInfo: Decodable {
        var info: UserInfoResponse.Info?
    }

    struct Metrics: Decodable {
        var spend: Flexible?
        var prompt_tokens: Double?
        var completion_tokens: Double?
        var total_tokens: Double?
        var successful_requests: Double?
        var failed_requests: Double?
        var api_requests: Double?
        var cache_read_input_tokens: Double?
        var prompt_caching_savings_spend: Double?

        var tokens: Double { total_tokens ?? (prompt_tokens ?? 0) + (completion_tokens ?? 0) }
        var requests: Double { api_requests ?? (successful_requests ?? 0) + (failed_requests ?? 0) }
    }

    struct ActivityResponse: Decodable {
        struct Result: Decodable {
            struct Breakdown: Decodable {
                struct Entry: Decodable { var metrics: Metrics? }
                var models: [String: Entry?]?
            }
            var date: String
            var metrics: Metrics?
            var breakdown: Breakdown?
        }
        struct Metadata: Decodable {
            var total_pages: Int?
            var has_more: Bool?
        }
        var results: [Result]?
        var metadata: Metadata?
    }
}
