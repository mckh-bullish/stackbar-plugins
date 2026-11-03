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
        version: "1.2.1",
        summary: "Tokens, spend, budget and model mix from your LiteLLM proxy, with charts.",
        surfaces: [.menuBar, .panel, .window, .widget, .settings],
        triggers: [.launch, .minutes(2), .wake],
        capabilities: [.userServer(secret: "LITELLM_PROXY_URL"), .secret(name: "LITELLM_API_KEY")],
        minimumStackbar: "0.14.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Monitoring/LiteLLM",
        accent: .pink,
        symbol: "sparkles"
    )

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

    /// Today's health, from the latest fetch.
    struct Today: Codable, Equatable {
        var date: String
        var requests: Double
        var failed: Double
        var promptTokens: Double
        var cacheReadTokens: Double
        var cacheSavings: Double
    }

    var problem: String?
    var proxy: String?

    // MARK: - Fetching

    func refresh() async throws {
        guard let url = try await Stackbar.secret("LITELLM_PROXY_URL")?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else {
            proxy = nil
            problem = "Enter your proxy's URL as LITELLM_PROXY_URL."
            return
        }
        let base = url.hasSuffix("/") ? String(url.dropLast()) : url
        proxy = base
        guard let key = try await Stackbar.secret("LITELLM_API_KEY")?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            problem = "Enter a LiteLLM key as LITELLM_API_KEY."
            return
        }
        do {
            async let info = fetchBudget(base: base, key: key)
            async let month = fetchDays(base: base, key: key, from: Self.day(-30), to: Self.day(0))
            let (newBudget, recent) = try await (info, month)
            budget = newBudget
            merge(recent.days)
            models = recent.models
            todayDetail = recent.today
            if historyFetched.map({ Date().timeIntervalSince($0) > 6 * 3600 }) ?? true {
                let history = try await fetchDays(base: base, key: key, from: Self.day(-182), to: Self.day(-31))
                merge(history.days)
                historyFetched = Date()
            }
            lastSuccess = Date()
            problem = nil
            notifyAboutBudget()
        } catch {
            problem = "\(error)"
        }
    }

    private func headers(_ key: String) -> [String: String] {
        ["Authorization": "Bearer \(key)", "Accept": "application/json"]
    }

    private func fetchBudget(base: String, key: String) async throws -> Budget? {
        let response = try await Stackbar.get(base + "/user/info", headers: headers(key))
        try check(response, what: "/user/info")
        let info = try JSONDecoder().decode(UserInfoResponse.self, from: response.body).user_info
        guard let info else { return nil }
        let max = info.max_budget?.value
        return Budget(spend: info.spend?.value ?? 0, max: max.flatMap { $0 > 0 ? $0 : nil }, resetAt: info.budget_reset_at.flatMap(Self.parseDate))
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
            let response = try await Stackbar.get(base + "/user/daily/activity?start_date=\(from)&end_date=\(to)&page=\(page)&page_size=100", headers: headers(key))
            try check(response, what: "/user/daily/activity")
            let activity = try JSONDecoder().decode(ActivityResponse.self, from: response.body)
            for result in activity.results ?? [] {
                let metrics = result.metrics ?? Metrics()
                fetched.days[result.date] = Day(tokens: metrics.tokens, spend: metrics.spend?.value ?? 0, requests: metrics.requests, failed: metrics.failed_requests ?? 0)
                if result.date == Self.day(0) {
                    fetched.today = Today(date: result.date, requests: metrics.requests, failed: metrics.failed_requests ?? 0,
                                          promptTokens: metrics.prompt_tokens ?? 0, cacheReadTokens: metrics.cache_read_input_tokens ?? 0,
                                          cacheSavings: metrics.prompt_caching_savings_spend ?? 0)
                }
                for (name, breakdown) in result.breakdown?.models ?? [:] {
                    let model = breakdown?.metrics ?? Metrics()
                    let short = Self.shortName(name)
                    var total = byModel[short] ?? Model(name: short, tokens: 0, spend: 0)
                    total.tokens += model.tokens
                    total.spend += model.spend?.value ?? 0
                    byModel[short] = total
                }
            }
            let pages = activity.metadata?.total_pages ?? 1
            guard activity.metadata?.has_more == true || page < pages else { break }
            page += 1
        }
        fetched.models = byModel.values.filter { $0.tokens > 0 || $0.spend > 0 }.sorted { $0.tokens > $1.tokens }
        return fetched
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
                trendCard
                Card("Activity", detail: "\(activeDays(0...181)) active days in 6 months") {
                    Chart(values: series(days: 182, measure: .tokens), kind: .heatmap, labels: dayLabels(182, format: "EEE d MMM"), unit: " tokens")
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
            Chart(values: series(days: 7, measure: measure), kind: .bar, labels: dayLabels(7, format: "EEE"), unit: unit, highlight: 6)
        case .month:
            Chart(values: series(days: 30, measure: measure), kind: .area, labels: sparseLabels(dayLabels(30, format: "MMM d"), every: 7), unit: unit, highlight: 29)
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

    var tools: [AgentTool] {
        AgentTool("usage_summary", description: "LiteLLM tokens and spend for today, 7 and 30 days, the budget and the top models") { _ in
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
        ago.reduce(into: Day(tokens: 0, spend: 0)) { sum, offset in
            let day = days[Self.day(-offset)] ?? Day(tokens: 0, spend: 0)
            sum.tokens += day.tokens
            sum.spend += day.spend
            sum.requests += day.requests
            sum.failed += day.failed
        }
    }

    func activeDays(_ ago: ClosedRange<Int>) -> Int {
        ago.filter { (days[Self.day(-$0)]?.tokens ?? 0) > 0 }.count
    }

    /// The last `count` days, oldest first.
    func series(days count: Int, measure: Measure) -> [Double] {
        (0..<count).reversed().map { offset in
            let day = days[Self.day(-offset)]
            return measure == .tokens ? day?.tokens ?? 0 : day?.spend ?? 0
        }
    }

    func dayLabels(_ count: Int, format: String) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return (0..<count).reversed().map { formatter.string(from: Calendar.current.date(byAdding: .day, value: -$0, to: Date()) ?? Date()) }
    }

    /// Keeps every `every`th label, counted back from the last, and blanks the
    /// rest so a month's axis stays readable.
    func sparseLabels(_ labels: [String], every: Int) -> [String] {
        labels.enumerated().map { index, label in (labels.count - 1 - index) % every == 0 ? label : "" }
    }

    func weekly(measure: Measure) -> (values: [Double], labels: [String]) {
        let daily = series(days: 182, measure: measure)
        let names = dayLabels(182, format: "MMM d")
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
        for model in models.prefix(5) {
            lines.append("\(model.name): \(Self.compact(model.tokens)) tokens, \(Self.money(model.spend, cents: true))")
        }
        if let problem { lines.append("Problem: \(problem)") }
        return lines.joined(separator: "\n")
    }

    // MARK: - Formatting

    static func day(_ offset: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date())
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
        var user_info: Info?
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
