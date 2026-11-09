import StackbarKit
import Foundation

/// Sums, unit and currency conversions and times across zones right in the
/// palette, as Raycast does: type `12*(3+4)`, `2^10`, `15% * 80`, `sqrt(2)`,
/// `3h in min`, `72 f to c`, `5 km in mi`, `100 usd in eur` or
/// `5pm london in tokyo` and the answer leads the results; Return copies it.
/// Plain numbers and words get no answer, so it never crowds a normal search.
@main
final class Calculator: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.calculator",
        name: "Calculator",
        version: "1.7.0",
        summary: "Sums, units, currencies and time zones answered right in the command palette.",
        surfaces: [.panel, .settings],
        // Exchange rates are fetched at launch, on wake and every six hours
        // after (and retried with a growing pause when a fetch fails), unless currency conversion is turned off in Settings.
        triggers: [.launch, .every(.seconds(6 * 3600)), .wake],
        capabilities: [.network("api.frankfurter.dev")],
        minimumStackbar: "0.21.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Productivity/Calculator",
        accent: .orange,
        symbol: "equal.square.fill"
    )

    static let previews: [PreviewScene<Calculator>] = [
        PreviewScene("hero", "Answers as you type") { plugin in
            plugin.history = [
                Entry(expression: "12*(3+4)", result: "84", display: "84"),
                Entry(expression: "5 km → mi", result: "3.106855961", display: "3.106855961 mi"),
                Entry(expression: "72 °F → °C", result: "22.22222222", display: "22.22222222 °C"),
            ]
        },
        PreviewScene("conversions", "Currencies and time zones too") { plugin in
            plugin.history = [
                Entry(expression: "100 USD → EUR · rates of 2026-11-06", result: "89.57", display: "89.57 EUR"),
                Entry(expression: "5:00 PM London → Tokyo (next day)", result: "2:00 AM", display: "2:00 AM in Tokyo"),
                Entry(expression: "60 mph → km/h", result: "96.56064", display: "96.56064 km/h"),
            ]
        },
    ]

    let theme = Theme.orange

    struct Entry: Codable, Equatable, Identifiable {
        var expression: String
        var result: String
        var display: String
        var id: String { expression }
    }

    /// The last answers copied, newest first.
    @Stored("history") var history: [Entry] = []

    /// The European Central Bank's reference rates, from Frankfurter (no
    /// key, about 30 currencies), kept so the palette never waits on them.
    @Stored("rates") var rates: Math.Rates? = nil

    /// Off: no exchange rates are fetched, so the plugin makes no network
    /// requests at all, and currency sums get no answer.
    @Stored("currency") var currency = true

    func refresh() async throws {
        guard currency else { return }
        if let rates, Date().timeIntervalSince(rates.fetched) < 6 * 3600 { return }
        do {
            try await fetchRates()
        } catch {
            retryRates()
            throw error
        }
    }

    func fetchRates() async throws {
        struct Latest: Decodable { var base: String; var date: String; var rates: [String: Double] }
        let latest: Latest = try await Stackbar.getJSON("https://api.frankfurter.dev/v1/latest?base=EUR")
        var table = latest.rates
        table[latest.base] = 1
        rates = Math.Rates(perEuro: table, date: latest.date, fetched: Date())
    }

    private var retrying: Task<Void, Never>?

    /// After a failed fetch (offline at launch, say), tries again after 30
    /// seconds, 2, 10 and 30 minutes instead of waiting for the next six-hour tick.
    private func retryRates() {
        guard retrying == nil else { return }
        retrying = Task {
            for pause in [30, 120, 600, 1800] {
                try? await Task.sleep(for: .seconds(pause))
                guard !Task.isCancelled, self.currency else { break }
                if (try? await self.fetchRates()) != nil { break }
            }
            self.retrying = nil
        }
    }

    func copy(_ answer: Math.Answer) {
        Stackbar.copy(answer.result)
        let entry = Entry(expression: answer.expression, result: answer.result, display: answer.display)
        history = Array(([entry] + history.filter { $0.expression != entry.expression }).prefix(10))
    }

    // MARK: Commands

    var commands: [Command] {
        Command("calculate", title: "Calculate", subtitle: "Sums, units, currencies and time zones", symbol: "equal.square", keywords: ["math", "sum", "convert", "units", "currency", "time zone"])
            .view { invocation in
                let typed = invocation.text.trimmingCharacters(in: .whitespaces)
                if let answer = Math.answer(invocation.text, rates: self.currency ? self.rates : nil) {
                    List {
                        // The title starts with what was typed, so the
                        // answer leads the palette's results.
                        Row("\(typed) = \(answer.display)", subtitle: answer.expression, symbol: "equal", key: "answer")
                            .action("Copy Answer") { self.copy(answer) }
                    }
                } else if (self.rates == nil || !self.currency) && Math.Rates.looksLikeMoney(invocation.text) {
                    ContentUnavailableView("No exchange rates", symbol: "dollarsign.arrow.circlepath", message: self.currency ? "Calculator couldn't reach api.frankfurter.dev yet. It tries again in a few minutes." : "Currency conversion is off in Calculator's settings.")
                } else if Math.undefined(invocation.text) {
                    ContentUnavailableView("No answer", symbol: "divide", message: "That divides by zero or has no real answer.")
                } else if typed.isEmpty, !self.history.isEmpty {
                    List {
                        Section("Recent answers") {
                            ForEach(self.history) { entry in
                                Row(entry.display, subtitle: entry.expression, symbol: "clock.arrow.circlepath", key: "history-" + entry.expression)
                                    .action("Copy Answer") { Stackbar.copy(entry.result) }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Type a sum", symbol: "equal.square", message: "Like 12*(3+4), 15% * 80, 3h in min, 100 usd in eur, 5pm london in tokyo or days until dec 20.")
                }
            }
            // Only text that can have an answer (a number, `now in
            // tokyo` or `days until christmas`) reaches it. A matched pattern also puts the answer
            // above everything else, so a past answer in the panel, which
            // the palette finds too, never sits on top of the live one.
            .rootSearch(section: "Calculator", matching: #"(?is).*(\p{N}| in | to | until | till | since ).*"#)
    }

    // MARK: Panel

    var panel: ViewContent {
        PanelHeader("Calculator", subtitle: "Type a sum in the palette", symbol: "equal.square.fill", theme: theme)
        if history.isEmpty {
            EmptyState("No answers yet", symbol: "equal.square", message: "Open the palette and type a sum or a conversion, like 3h in min. The answer comes first; Return copies it.", theme: theme)
        } else {
            Card("Recent answers", spacing: 0, padding: Space.s) {
                ForEach(history) { entry in
                    Row(entry.display, subtitle: entry.expression, symbol: "equal", key: entry.id)
                        .action("Copy") { Stackbar.copy(entry.result) }
                }
            }
        }
    }

    // MARK: Settings

    var settings: ViewContent {
        Section("Currencies") {
            Toggle("Convert currencies", isOn: currency) { on in
                self.currency = on
                if on {
                    try await self.refresh()
                } else {
                    self.rates = nil
                }
            }
            Text(currency
                ? "Exchange rates come from api.frankfurter.dev (the European Central Bank's reference rates), fetched at launch and every six hours."
                : "Off: Calculator makes no network requests. Sums, units and time zones still work.").role(.secondary)
        }
    }

    // MARK: Math

    /// The parser and the unit table, with no host calls, so it is quick
    /// enough to run on every keystroke.
    enum Math {
        struct Answer: Equatable, Sendable {
            /// What was understood, like `3 h → min`.
            var expression: String
            /// The answer as shown and copied, like `180`.
            var result: String
            /// With its unit, like `180 min`; the same as `result` for a sum.
            var display: String
        }

        static func answer(_ query: String, rates: Rates? = nil, now: Date = Date(), here: TimeZone = .current) -> Answer? {
            let text = query.trimmingCharacters(in: .whitespaces)
            guard text.count <= 200 else { return nil }
            if let time = Times.answer(text, now: now, here: here) { return time }
            if let date = Dates.answer(text, now: now, here: here) { return date }
            guard text.contains(where: \.isNumber) else { return nil }
            if let conversion = convert(text) { return conversion }
            if let rates, let money = rates.convert(text) { return money }
            var parser = Parser(text)
            guard let value = parser.parse(), parser.sawOperator, value.isFinite else { return nil }
            let result = format(value)
            return Answer(expression: text, result: result, display: result)
        }

        /// A sum that has an operator but no real answer, like `1/0`.
        static func undefined(_ query: String) -> Bool {
            let text = query.trimmingCharacters(in: .whitespaces)
            var parser = Parser(text)
            guard let value = parser.parse(), parser.sawOperator else { return false }
            return !value.isFinite
        }

        // MARK: Numbers

        /// Up to ten significant digits, no trailing zeros, no exponent for
        /// everyday sizes.
        static func format(_ value: Double, decimalComma: Bool = Math.localeUsesDecimalComma) -> String {
            let text = point(value)
            return decimalComma && !text.contains("e") ? text.replacingOccurrences(of: ".", with: ",") : text
        }

        /// `format` with a point as the decimal mark.
        private static func point(_ value: Double) -> String {
            let value = value == 0 ? 0 : value // no "-0"
            if value.rounded() == value, abs(value) < 1e15 { return String(Int64(value)) }
            var text = String(format: "%.10g", value)
            if text.contains("e") { return text }
            if text.contains(".") {
                while text.hasSuffix("0") { text.removeLast() }
                if text.hasSuffix(".") { text.removeLast() }
            }
            return text
        }

        /// Whether this Mac writes 2,5 for two and a half.
        static let localeUsesDecimalComma = Locale.current.decimalSeparator == ","

        /// A number as typed, with `.` or `,` as the decimal mark or as
        /// thousands separators:
        /// - `1,234.56` and `1.234,56` have both, so the last one is the decimal mark;
        /// - `1,234,567` is a thousands grouping, and `2,5` or `0,500` cannot be one,
        ///   so a comma there is a decimal comma;
        /// - a single separator before exactly three digits (`1,000`) is a
        ///   thousands separator, unless this Mac's decimal mark is that very
        ///   character (a German Mac reads `1,000` as 1 and `1.000` as 1000);
        /// - commas in the Indian style (`1,00,000`, `12,34,567`: a last group
        ///   of three, earlier groups of two) are thousands grouping too;
        /// - a lone `.` or `,` is not a number.
        static func number(_ token: String, decimalComma: Bool) -> Double? {
            guard !token.isEmpty, token.contains(where: \.isNumber) else { return nil }
            /// `1,234,567`: one to three digits, then groups of exactly three;
            /// or, with commas, `12,34,567`: one or two digits, groups of two,
            /// then a last group of three.
            func grouped(_ text: Substring, by mark: Character) -> Bool {
                let parts = text.split(separator: mark, omittingEmptySubsequences: false)
                guard parts.count >= 2, let first = parts.first, (1...3).contains(first.count), first.first != "0" else { return false }
                guard parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return false }
                if parts.dropFirst().allSatisfy({ $0.count == 3 }) { return true }
                guard mark == ",", parts.count >= 3, first.count <= 2, parts.last?.count == 3 else { return false }
                return parts.dropFirst().dropLast().allSatisfy { $0.count == 2 }
            }
            func clean(_ text: Substring, mark: Character) -> String { text.filter { $0 != mark } }
            let hasDot = token.contains("."), hasComma = token.contains(",")
            var normalized: String
            switch (hasDot, hasComma) {
            case (false, false):
                normalized = token
            case (true, true):
                guard let dot = token.lastIndex(of: "."), let comma = token.lastIndex(of: ",") else { return nil }
                let (group, decimal): (Character, Character) = dot > comma ? (",", ".") : (".", ",")
                let parts = token.split(separator: decimal, omittingEmptySubsequences: false)
                guard parts.count == 2, grouped(parts[0], by: group) else { return nil }
                normalized = clean(parts[0], mark: group) + "." + parts[1]
            default:
                let mark: Character = hasComma ? "," : "."
                let parts = token.split(separator: mark, omittingEmptySubsequences: false)
                let isGrouping = grouped(Substring(token), by: mark)
                let isLocaleDecimalMark = (mark == ",") == decimalComma
                if parts.count > 2 {
                    guard isGrouping else { return nil }
                    normalized = clean(Substring(token), mark: mark)
                } else if isGrouping && !isLocaleDecimalMark {
                    normalized = clean(Substring(token), mark: mark)
                } else {
                    normalized = (parts[0].isEmpty ? "0" : String(parts[0])) + (parts[1].isEmpty ? "" : "." + parts[1])
                }
            }
            return Double(normalized)
        }

        /// Recursive descent: + - over * / % over unary minus over ^ over
        /// numbers, parentheses, `pi`, `e` and `sqrt(…)`.
        struct Parser {
            private let characters: [Character]
            private var index = 0
            private(set) var sawOperator = false
            /// Whether the last product was a bare percent (`10%`), which a sum
            /// adds or takes as a share of the amount before it.
            private var lastWasBarePercent = false

            private let decimalComma: Bool

            init(_ text: String, decimalComma: Bool = Math.localeUsesDecimalComma) {
                characters = Array(text.lowercased())
                self.decimalComma = decimalComma
            }

            mutating func parse() -> Double? {
                guard let value = sum() else { return nil }
                skipSpaces()
                return index == characters.count ? value : nil
            }

            private mutating func skipSpaces() {
                while index < characters.count, characters[index].isWhitespace { index += 1 }
            }

            private mutating func take(_ options: Set<Character>) -> Character? {
                skipSpaces()
                guard index < characters.count, options.contains(characters[index]) else { return nil }
                defer { index += 1 }
                return characters[index]
            }

            private mutating func sum() -> Double? {
                guard var value = product() else { return nil }
                // `100 + 10%` adds a tenth of 100, but `10% + 5%` is 15%, not a
                // share of 10%: a bare percent on the left is already a fraction.
                var leftIsPercent = lastWasBarePercent
                while let sign = take(["+", "-", "−"]) {
                    sawOperator = true
                    guard let next = product() else { return nil }
                    let delta = lastWasBarePercent && !leftIsPercent ? value * next : next
                    value = sign == "+" ? value + delta : value - delta
                    leftIsPercent = false
                }
                return value
            }

            private mutating func product() -> Double? {
                guard var value = unary() else { return nil }
                // Only a number and its % signs is a bare percent: in `200 + 100 * 10%`
                // the percent takes the product, so it is a plain 10.
                var sawPercent = false
                var sawMultiplication = false
                while true {
                    if take(["%"]) != nil {
                        // `15%` alone is 0.15; `10 % 3` would read as a modulo
                        // nobody types here, so % is always a percent.
                        sawOperator = true
                        sawPercent = true
                        value /= 100
                        continue
                    }
                    guard let sign = take(["*", "/", "×", "÷", "x"]) else {
                        lastWasBarePercent = sawPercent && !sawMultiplication
                        return value
                    }
                    sawOperator = true
                    sawMultiplication = true
                    guard let next = unary() else { return nil }
                    value = (sign == "/" || sign == "÷") ? value / next : value * next
                }
            }

            private mutating func unary() -> Double? {
                if take(["-", "−"]) != nil {
                    return power().map { -$0 }
                }
                _ = take(["+"])
                return power()
            }

            private mutating func power() -> Double? {
                guard let base = atom() else { return nil }
                if take(["^"]) != nil {
                    sawOperator = true
                    guard let exponent = unary() else { return nil }
                    return pow(base, exponent)
                }
                return base
            }

            private mutating func atom() -> Double? {
                skipSpaces()
                guard index < characters.count else { return nil }
                if take(["("]) != nil {
                    guard let value = sum(), take([")"]) != nil else { return nil }
                    return value
                }
                if word("sqrt") {
                    sawOperator = true
                    guard take(["("]) != nil, let value = sum(), take([")"]) != nil else { return nil }
                    return value.squareRoot()
                }
                if word("pi") || word("π") { return .pi }
                if constant("e") { return M_E }
                return number()
            }

            private mutating func word(_ name: String) -> Bool {
                skipSpaces()
                let letters = Array(name)
                guard index + letters.count <= characters.count, Array(characters[index..<index + letters.count]) == letters else { return false }
                index += letters.count
                return true
            }

            /// A one-letter constant, unless letters follow it (`exp` is not `e`).
            private mutating func constant(_ letter: Character) -> Bool {
                skipSpaces()
                guard index < characters.count, characters[index] == letter else { return false }
                guard index + 1 >= characters.count || !characters[index + 1].isLetter else { return false }
                index += 1
                return true
            }

            private mutating func number() -> Double? {
                let start = index
                while index < characters.count, characters[index].isNumber || characters[index] == "." || characters[index] == "," {
                    index += 1
                }
                return Math.number(String(characters[start..<index]), decimalComma: decimalComma)
            }
        }

        // MARK: Units

        struct Unit {
            var symbol: String
            var category: String
            /// How many of the category's base unit one of these is.
            var factor: Double
        }

        /// Every spelling a unit is typed with, lowercased.
        static let units: [String: Unit] = {
            var table: [String: Unit] = [:]
            func add(_ category: String, _ symbol: String, _ factor: Double, _ names: [String]) {
                for name in names + [symbol.lowercased()] { table[name] = Unit(symbol: symbol, category: category, factor: factor) }
            }
            add("length", "mm", 0.001, ["millimeter", "millimeters", "millimetre", "millimetres"])
            add("length", "cm", 0.01, ["centimeter", "centimeters", "centimetre", "centimetres"])
            add("length", "m", 1, ["meter", "meters", "metre", "metres"])
            add("length", "km", 1000, ["kilometer", "kilometers", "kilometre", "kilometres"])
            add("length", "in", 0.0254, ["inch", "inches", "\""])
            add("length", "ft", 0.3048, ["foot", "feet", "'"])
            add("length", "yd", 0.9144, ["yard", "yards"])
            add("length", "mi", 1609.344, ["mile", "miles"])
            add("mass", "mg", 0.001, ["milligram", "milligrams"])
            add("mass", "g", 1, ["gram", "grams"])
            add("mass", "kg", 1000, ["kilogram", "kilograms", "kilo", "kilos"])
            add("mass", "oz", 28.349523125, ["ounce", "ounces"])
            add("mass", "lb", 453.59237, ["lbs", "pound", "pounds"])
            add("mass", "t", 1_000_000, ["tonne", "tonnes"])
            add("time", "ms", 0.001, ["millisecond", "milliseconds"])
            add("time", "s", 1, ["sec", "secs", "second", "seconds"])
            add("time", "min", 60, ["mins", "minute", "minutes"])
            add("time", "h", 3600, ["hr", "hrs", "hour", "hours"])
            add("time", "d", 86400, ["day", "days"])
            add("time", "wk", 604_800, ["week", "weeks"])
            add("data", "B", 1, ["byte", "bytes"])
            add("data", "KB", 1e3, ["kilobyte", "kilobytes"])
            add("data", "MB", 1e6, ["megabyte", "megabytes"])
            add("data", "GB", 1e9, ["gigabyte", "gigabytes"])
            add("data", "TB", 1e12, ["terabyte", "terabytes"])
            add("data", "KiB", 1024, [])
            add("data", "MiB", 1_048_576, [])
            add("data", "GiB", 1_073_741_824, [])
            add("volume", "ml", 0.001, ["milliliter", "milliliters", "millilitre", "millilitres"])
            add("volume", "l", 1, ["liter", "liters", "litre", "litres"])
            add("volume", "tsp", 0.00492892159375, ["teaspoon", "teaspoons"])
            add("volume", "tbsp", 0.01478676478125, ["tablespoon", "tablespoons"])
            add("volume", "fl oz", 0.0295735295625, ["floz"])
            add("volume", "cup", 0.2365882365, ["cups"])
            add("volume", "gal", 3.785411784, ["gallon", "gallons"])
            add("speed", "m/s", 1, ["mps"])
            add("speed", "km/h", 1 / 3.6, ["kph", "kmh", "kmph"])
            add("speed", "mph", 0.44704, [])
            add("speed", "kn", 0.514444, ["knot", "knots", "kt"])
            add("temperature", "°C", 1, ["c", "celsius", "°c"])
            add("temperature", "°F", 1, ["f", "fahrenheit", "°f"])
            add("temperature", "K", 1, ["kelvin"])
            return table
        }()

        /// `<sum> <unit> in|to|as <unit>`.
        static func convert(_ text: String) -> Answer? {
            let lower = text.lowercased()
            // The last ` in `/` to `/` as ` whose right side is a unit, so
            // `12 in to cm` reads as inches to centimetres.
            var found: (left: String, to: Unit, at: Int)?
            for word in [" in ", " to ", " as "] {
                guard let range = lower.range(of: word, options: .backwards),
                      let unit = units[lower[range.upperBound...].trimmingCharacters(in: .whitespaces)] else { continue }
                let at = range.lowerBound.utf16Offset(in: lower)
                if let current = found, current.at > at { continue }
                found = (String(lower[..<range.lowerBound]), unit, at)
            }
            guard let found else { return nil }
            let to = found.to
            // The unit is everything after the last digit or closing bracket:
            // `5km`, `3 h`, `2 fl oz`, `(1+2) mi`.
            let left = found.left.trimmingCharacters(in: .whitespaces)
            guard let lastValue = left.lastIndex(where: { $0.isNumber || $0 == ")" || $0 == "." }) else { return nil }
            let amountText = String(left[...lastValue])
            let unitText = left[left.index(after: lastValue)...].trimmingCharacters(in: .whitespaces)
            guard let from = units[unitText], from.category == to.category else { return nil }
            var parser = Parser(amountText)
            guard let amount = parser.parse(), amount.isFinite else {
                return compound(left, to: to)
            }
            let value: Double
            if from.category == "temperature" {
                value = celsius(amount, from: from.symbol).map { fromCelsius($0, to: to.symbol) } ?? .nan
            } else {
                value = amount * from.factor / to.factor
            }
            guard value.isFinite else { return nil }
            let result = format(value)
            return Answer(expression: "\(format(amount)) \(from.symbol) → \(to.symbol)", result: result, display: "\(result) \(to.symbol)")
        }

        /// A mixed amount such as `5 ft 10 in` or `1h 30min`: each part a
        /// number and a unit of the target's kind (not temperatures).
        static func compound(_ left: String, to: Unit) -> Answer? {
            guard to.category != "temperature" else { return nil }
            var rest = Substring(left)
            var total = 0.0
            var parts: [String] = []
            while !rest.isEmpty {
                rest = rest.drop { $0 == " " }
                let number = rest.prefix { $0.isNumber || $0 == "." }
                guard !number.isEmpty, let value = Double(number) else { return nil }
                rest = rest.dropFirst(number.count).drop { $0 == " " }
                let name = rest.prefix { !$0.isNumber && $0 != " " }
                guard let unit = units[String(name)], unit.category == to.category else { return nil }
                rest = rest.dropFirst(name.count)
                total += value * unit.factor
                parts.append(format(value) + " " + unit.symbol)
            }
            guard parts.count > 1 else { return nil }
            let result = format(total / to.factor)
            return Answer(expression: parts.joined(separator: " ") + " → \(to.symbol)", result: result, display: "\(result) \(to.symbol)")
        }

        private static func celsius(_ value: Double, from symbol: String) -> Double? {
            switch symbol {
            case "°C": return value
            case "°F": return (value - 32) * 5 / 9
            case "K": return value - 273.15
            default: return nil
            }
        }

        private static func fromCelsius(_ value: Double, to symbol: String) -> Double {
            switch symbol {
            case "°F": return value * 9 / 5 + 32
            case "K": return value + 273.15
            default: return value
            }
        }

        // MARK: Currencies

        struct Rates: Codable, Equatable, Sendable {
            /// Units of each currency one euro buys, EUR itself included.
            var perEuro: [String: Double]
            /// The day the bank published them, like `2026-11-04`.
            var date: String
            var fetched: Date

            /// Symbols and words for the codes people type most.
            static let names: [String: String] = [
                "$": "USD", "dollar": "USD", "dollars": "USD", "usd": "USD",
                "€": "EUR", "euro": "EUR", "euros": "EUR",
                "£": "GBP", "pound": "GBP", "pounds": "GBP", "quid": "GBP",
                "¥": "JPY", "yen": "JPY",
                "₹": "INR", "rupee": "INR", "rupees": "INR", "rs": "INR",
                "₩": "KRW", "won": "KRW",
                "fr": "CHF", "franc": "CHF", "francs": "CHF",
                "a$": "AUD", "c$": "CAD", "s$": "SGD", "hk$": "HKD", "r$": "BRL",
                "yuan": "CNY", "rmb": "CNY", "kr": "SEK", "zł": "PLN",
            ]

            /// The currencies the bank publishes, so a sum in one of them is known even without rates.
            static let knownCodes: Set<String> = ["AUD", "BGN", "BRL", "CAD", "CHF", "CNY", "CZK", "DKK", "EUR", "GBP", "HKD", "HUF", "IDR", "ILS", "INR", "ISK", "JPY", "KRW", "MXN", "MYR", "NOK", "NZD", "PHP", "PLN", "RON", "SEK", "SGD", "THB", "TRY", "USD", "ZAR"]

            /// Whether `text` converts between currencies, whether or not there are rates.
            static func looksLikeMoney(_ text: String) -> Bool {
                Rates(perEuro: Dictionary(uniqueKeysWithValues: knownCodes.map { ($0, 1.0) }), date: "", fetched: .distantPast).convert(text) != nil
            }

            func code(_ word: String) -> String? {
                let word = word.trimmingCharacters(in: .whitespaces).lowercased()
                if let code = Self.names[word], perEuro[code] != nil { return code }
                let upper = word.uppercased()
                return upper.count == 3 && perEuro[upper] != nil ? upper : nil
            }

            /// `<sum> <currency> in|to|as <currency>`, with the currency
            /// before or after the amount (`$100`, `100 usd`).
            func convert(_ text: String) -> Answer? {
                let lower = text.lowercased()
                for word in [" in ", " to ", " as "] {
                    guard let range = lower.range(of: word, options: .backwards),
                          let to = code(String(lower[range.upperBound...])) else { continue }
                    let left = lower[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                    guard let (amount, from) = amount(left), let fromRate = perEuro[from], let toRate = perEuro[to], fromRate > 0 else { continue }
                    let value = amount / fromRate * toRate
                    guard value.isFinite else { return nil }
                    let result = Self.money(value)
                    return Answer(expression: "\(Math.format(amount)) \(from) → \(to) · rates of \(date)", result: result, display: "\(result) \(to)")
                }
                return nil
            }

            /// The amount and its currency: `100 usd`, `100usd`, `$100`,
            /// `€ 12.50`, `(2+3) gbp`.
            private func amount(_ text: String) -> (Double, String)? {
                if let first = text.firstIndex(where: { $0.isNumber || $0 == "(" || $0 == "." }), first != text.startIndex,
                   let from = code(String(text[..<first])) {
                    var parser = Parser(String(text[first...]))
                    if let value = parser.parse(), value.isFinite { return (value, from) }
                }
                guard let last = text.lastIndex(where: { $0.isNumber || $0 == ")" || $0 == "." }),
                      let from = code(String(text[text.index(after: last)...])) else { return nil }
                var parser = Parser(String(text[...last]))
                guard let value = parser.parse(), value.isFinite else { return nil }
                return (value, from)
            }

            /// Two decimals, or more for tiny amounts, with no exponent.
            static func money(_ value: Double, decimalComma: Bool = Math.localeUsesDecimalComma) -> String {
                let text = abs(value) >= 1 || value == 0 ? String(format: "%.2f", value) : Math.format(value, decimalComma: false)
                return decimalComma && !text.contains("e") ? text.replacingOccurrences(of: ".", with: ",") : text
            }
        }

        // MARK: Time zones

        enum Times {
            /// Cities, countries and abbreviations people type, beyond the
            /// city part of every time zone identifier (`tokyo`, `new york`).
            static let aliases: [String: String] = [
                "nyc": "America/New_York", "ny": "America/New_York", "boston": "America/New_York", "miami": "America/New_York", "washington": "America/New_York",
                "sf": "America/Los_Angeles", "san francisco": "America/Los_Angeles", "la": "America/Los_Angeles", "seattle": "America/Los_Angeles", "california": "America/Los_Angeles",
                "austin": "America/Chicago", "dallas": "America/Chicago", "houston": "America/Chicago",
                "uk": "Europe/London", "england": "Europe/London", "edinburgh": "Europe/London",
                "india": "Asia/Kolkata", "bangalore": "Asia/Kolkata", "bengaluru": "Asia/Kolkata", "delhi": "Asia/Kolkata", "mumbai": "Asia/Kolkata", "chennai": "Asia/Kolkata", "hyderabad": "Asia/Kolkata",
                "japan": "Asia/Tokyo", "china": "Asia/Shanghai", "beijing": "Asia/Shanghai", "germany": "Europe/Berlin", "munich": "Europe/Berlin",
                "france": "Europe/Paris", "spain": "Europe/Madrid", "barcelona": "Europe/Madrid", "italy": "Europe/Rome", "milan": "Europe/Rome",
                "netherlands": "Europe/Amsterdam", "australia": "Australia/Sydney", "melbourne": "Australia/Melbourne", "dubai": "Asia/Dubai", "uae": "Asia/Dubai",
                "korea": "Asia/Seoul", "taiwan": "Asia/Taipei", "brazil": "America/Sao_Paulo", "canada": "America/Toronto", "vancouver": "America/Vancouver",
                "utc": "UTC", "gmt": "GMT", "pst": "America/Los_Angeles", "pdt": "America/Los_Angeles", "pt": "America/Los_Angeles",
                "est": "America/New_York", "edt": "America/New_York", "et": "America/New_York", "cst": "America/Chicago", "cdt": "America/Chicago",
                "mst": "America/Denver", "ist": "Asia/Kolkata", "cet": "Europe/Paris", "cest": "Europe/Paris", "bst": "Europe/London", "jst": "Asia/Tokyo", "sgt": "Asia/Singapore",
                "aest": "Australia/Sydney",
            ]

            static let cities: [String: String] = {
                var table: [String: String] = [:]
                for identifier in TimeZone.knownTimeZoneIdentifiers {
                    guard let city = identifier.split(separator: "/").last else { continue }
                    table[city.replacingOccurrences(of: "_", with: " ").lowercased()] = identifier
                }
                return table.merging(aliases) { _, alias in alias }
            }()

            static func zone(_ name: String) -> (TimeZone, String)? {
                // Accents fold for the lookup only, so "são paulo" finds São Paulo and is shown as typed.
                let typed = name.trimmingCharacters(in: .whitespaces).lowercased()
                let key = typed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                guard !key.isEmpty, let identifier = cities[key], let zone = TimeZone(identifier: identifier) else { return nil }
                let shown = typed.count <= 4 ? typed.uppercased() : typed.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
                return (zone, shown)
            }

            /// `now in tokyo`, `time in london`, `5pm in tokyo`,
            /// `9:30 am nyc to london`, `17:00 berlin in sf`.
            static func answer(_ text: String, now: Date, here: TimeZone) -> Answer? {
                let lower = text.lowercased()
                guard let range = lower.range(of: " in ", options: .backwards) ?? lower.range(of: " to ", options: .backwards),
                      let (target, targetName) = zone(String(lower[range.upperBound...])) else { return nil }
                let left = lower[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let when: Date
                var source = here
                var sourceName = "here"
                if left == "now" || left == "time" || left == "time now" {
                    when = now
                } else {
                    guard let (clock, rest) = clockTime(left) else { return nil }
                    if !rest.isEmpty {
                        guard let (zone, name) = zone(rest) else { return nil }
                        source = zone
                        sourceName = name
                    }
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = source
                    var day = calendar.dateComponents([.year, .month, .day], from: now)
                    day.hour = clock.hour
                    day.minute = clock.minute
                    guard let date = calendar.date(from: day) else { return nil }
                    when = date
                }
                let result = Self.clock(when, in: target)
                var expression = "\(Self.clock(when, in: source)) \(sourceName) → \(targetName)"
                let dayShift = Self.dayOffset(when, from: source, to: target)
                if dayShift != 0 { expression += dayShift > 0 ? " (next day)" : " (previous day)" }
                return Answer(expression: expression, result: result, display: "\(result) in \(targetName)")
            }

            /// Compiled once, not on every keystroke.
            private static let clockPattern = try? NSRegularExpression(pattern: #"^(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?(?=\s|$)"#)

            /// A clock time at the start of the text, and what follows it:
            /// `5pm`, `5 pm`, `5:30pm`, `17:00`, `noon`, `midnight`.
            static func clockTime(_ text: String) -> ((hour: Int, minute: Int), String)? {
                for (word, hour) in [("noon", 12), ("midnight", 0)] where text.hasPrefix(word) {
                    return ((hour, 0), String(text.dropFirst(word.count)).trimmingCharacters(in: .whitespaces))
                }
                guard let regex = clockPattern,
                      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                      let hourRange = Range(match.range(at: 1), in: text), var hour = Int(text[hourRange]) else { return nil }
                let minute = Range(match.range(at: 2), in: text).flatMap { Int(text[$0]) }
                let meridiem = Range(match.range(at: 3), in: text).map { String(text[$0]) }
                // A bare number is a sum, not a time: `5 in tokyo` is nothing.
                guard minute != nil || meridiem != nil else { return nil }
                if let meridiem {
                    guard (1...12).contains(hour) else { return nil }
                    if meridiem.hasPrefix("p"), hour != 12 { hour += 12 }
                    if meridiem.hasPrefix("a"), hour == 12 { hour = 0 }
                }
                guard (0...23).contains(hour), (0...59).contains(minute ?? 0),
                      let whole = Range(match.range, in: text) else { return nil }
                return ((hour, minute ?? 0), text[whole.upperBound...].trimmingCharacters(in: .whitespaces))
            }

            private static let clockFormatter: DateFormatter = {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "h:mm a"
                return formatter
            }()

            static func clock(_ date: Date, in zone: TimeZone) -> String {
                clockFormatter.timeZone = zone
                return clockFormatter.string(from: date)
            }

            static func dayOffset(_ date: Date, from source: TimeZone, to target: TimeZone) -> Int {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = source
                let a = calendar.dateComponents([.year, .month, .day], from: date)
                calendar.timeZone = target
                let b = calendar.dateComponents([.year, .month, .day], from: date)
                guard let first = Calendar(identifier: .gregorian).date(from: a), let second = Calendar(identifier: .gregorian).date(from: b) else { return 0 }
                return Calendar(identifier: .gregorian).dateComponents([.day], from: first, to: second).day ?? 0
            }
        }
    }
}

extension Calculator.Math {
    /// Date math: `days until dec 20`, `days since 2026-01-01`,
    /// `weeks until christmas`, `today + 3 weeks`, `in 10 days`,
    /// `friday - 2 days`.
    enum Dates {
        static func answer(_ text: String, now: Date, here: TimeZone) -> Answer? {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = here
            let lower = text.lowercased().split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            let today = calendar.startOfDay(for: now)
            return between(lower, today: today, calendar: calendar) ?? shifted(lower, today: today, calendar: calendar)
        }

        /// `days until dec 20`, `weeks since jan 1`: a whole count.
        static func between(_ text: String, today: Date, calendar: Calendar) -> Answer? {
            let units: [(String, Calendar.Component)] = [("days", .day), ("weeks", .weekOfYear), ("months", .month), ("years", .year)]
            for (word, component) in units {
                for (link, future) in [("until", true), ("till", true), ("to", true), ("since", false)] {
                    let prefix = "\(word) \(link) "
                    guard text.hasPrefix(prefix), let date = day(String(text.dropFirst(prefix.count)), today: today, calendar: calendar, future: future) else { continue }
                    let from = future ? today : date
                    let to = future ? date : today
                    let count: Int
                    if component == .weekOfYear {
                        count = (calendar.dateComponents([.day], from: from, to: to).day ?? 0) / 7
                    } else {
                        count = calendar.dateComponents([component], from: from, to: to).value(for: component) ?? 0
                    }
                    let unit = count == 1 ? String(word.dropLast()) : word
                    let result = String(count)
                    return Answer(expression: "\(word.capitalized) \(link) \(long(date, calendar: calendar))", result: result, display: "\(result) \(unit)")
                }
            }
            return nil
        }

        /// `today + 3 weeks`, `in 10 days`, `dec 20 - 2 weeks`: a date.
        static func shifted(_ text: String, today: Date, calendar: Calendar) -> Answer? {
            let start: Date
            let sign: Int
            let amount: Substring
            if text.hasPrefix("in "), text.count > 3 {
                start = today
                sign = 1
                amount = text.dropFirst(3)
            } else if let range = text.range(of: " + ") ?? text.range(of: " - ") {
                guard let base = day(String(text[..<range.lowerBound]), today: today, calendar: calendar, future: true) else { return nil }
                start = base
                sign = text[range].contains("-") ? -1 : 1
                amount = text[range.upperBound...]
            } else {
                return nil
            }
            let parts = amount.split(separator: " ")
            guard parts.count == 2, let count = Int(parts[0]) else { return nil }
            let component: Calendar.Component
            switch parts[1] {
            case "day", "days", "d": component = .day
            case "week", "weeks", "w", "wk", "wks": component = .weekOfYear
            case "month", "months", "mo": component = .month
            case "year", "years", "y", "yr", "yrs": component = .year
            default: return nil
            }
            guard abs(count) <= 10_000, let date = calendar.date(byAdding: component, value: sign * count, to: start) else { return nil }
            let result = long(date, calendar: calendar)
            return Answer(expression: text, result: result, display: result)
        }

        /// A day by name: `today`, `tomorrow`, `friday`, `christmas`,
        /// `dec 20`, `20 december 2027`, `2026-12-20`, `12/20`. Without a
        /// year, the next one (`future`) or the last one.
        static func day(_ text: String, today: Date, calendar: Calendar, future: Bool) -> Date? {
            let text = text.trimmingCharacters(in: .whitespaces)
            switch text {
            case "today", "now": return today
            case "tomorrow": return calendar.date(byAdding: .day, value: 1, to: today)
            case "yesterday": return calendar.date(byAdding: .day, value: -1, to: today)
            default: break
            }
            let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
            if let index = weekdays.firstIndex(where: { $0 == text || $0.prefix(3) == text }) {
                let current = calendar.component(.weekday, from: today) - 1
                var offset = (index - current + 7) % 7
                if !future { offset = offset == 0 ? 0 : offset - 7 }
                return calendar.date(byAdding: .day, value: offset, to: today)
            }
            let named: [String: (month: Int, day: Int)] = [
                "christmas": (12, 25), "xmas": (12, 25), "new year": (1, 1), "new years": (1, 1), "new year's day": (1, 1),
                "halloween": (10, 31), "valentines": (2, 14), "valentine's day": (2, 14),
            ]
            if let (month, day) = named[text] { return nearest(month: month, day: day, today: today, calendar: calendar, future: future) }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.isLenient = false
            for format in ["yyyy-MM-dd", "MMM d yyyy", "MMMM d yyyy", "d MMM yyyy", "d MMMM yyyy", "MMM d, yyyy", "MMMM d, yyyy", "M/d/yyyy"] {
                formatter.dateFormat = format
                if let date = formatter.date(from: text) { return calendar.startOfDay(for: date) }
            }
            for format in ["MMM d", "MMMM d", "d MMM", "d MMMM", "M/d"] {
                formatter.dateFormat = format
                if let date = formatter.date(from: text) {
                    let parts = Calendar(identifier: .gregorian).dateComponents(in: calendar.timeZone, from: date)
                    guard let month = parts.month, let day = parts.day else { continue }
                    return nearest(month: month, day: day, today: today, calendar: calendar, future: future)
                }
            }
            return nil
        }

        /// This year's `month`/`day`, or next year's when it has passed
        /// (last year's when it is still to come, looking back).
        static func nearest(month: Int, day: Int, today: Date, calendar: Calendar, future: Bool) -> Date? {
            let year = calendar.component(.year, from: today)
            guard let this = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
            if future, this < today { return calendar.date(from: DateComponents(year: year + 1, month: month, day: day)) }
            if !future, this > today { return calendar.date(from: DateComponents(year: year - 1, month: month, day: day)) }
            return this
        }

        static func long(_ date: Date, calendar: Calendar) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "EEE, d MMM yyyy"
            return formatter.string(from: date)
        }
    }
}
