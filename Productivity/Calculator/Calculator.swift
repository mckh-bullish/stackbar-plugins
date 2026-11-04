import StackbarKit
import Foundation

/// Sums and unit conversions right in the palette, as Raycast does: type
/// `12*(3+4)`, `2^10`, `15% * 80`, `sqrt(2)`, `3h in min`, `72 f to c` or
/// `5 km in mi` and the answer leads the results; Return copies it. Plain
/// numbers and words get no answer, so it never crowds a normal search.
@main
final class Calculator: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.calculator",
        name: "Calculator",
        version: "1.0.0",
        summary: "Sums and unit conversions answered right in the command palette.",
        surfaces: [.panel],
        triggers: [.launch],
        minimumStackbar: "0.20.0",
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

    func copy(_ answer: Math.Answer) {
        Stackbar.copy(answer.result)
        let entry = Entry(expression: answer.expression, result: answer.result, display: answer.display)
        history = Array(([entry] + history.filter { $0.expression != entry.expression }).prefix(10))
    }

    // MARK: Commands

    var commands: [Command] {
        Command("calculate", title: "Calculate", subtitle: "Sums and unit conversions", symbol: "equal.square", keywords: ["math", "sum", "convert", "units"])
            .view { invocation in
                if let answer = Math.answer(invocation.text) {
                    List {
                        // The title starts with what was typed, so the
                        // answer leads the palette's results.
                        Row("\(invocation.text.trimmingCharacters(in: .whitespaces)) = \(answer.display)", subtitle: answer.expression, symbol: "equal", key: "answer")
                            .action("Copy Answer") { self.copy(answer) }
                            .action("Paste Answer", shortcut: "cmd+return") {
                                self.copy(answer)
                                try await Stackbar.paste(.text(answer.result), restoringClipboard: true)
                            }
                    }
                } else {
                    ContentUnavailableView("Type a sum", symbol: "equal.square", message: "Like 12*(3+4), 15% * 80, 3h in min or 72 f to c.")
                }
            }
            .rootSearch(section: "Calculator")
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

        static func answer(_ query: String) -> Answer? {
            let text = query.trimmingCharacters(in: .whitespaces)
            guard text.contains(where: \.isNumber), text.count <= 200 else { return nil }
            if let conversion = convert(text) { return conversion }
            var parser = Parser(text)
            guard let value = parser.parse(), parser.sawOperator, value.isFinite else { return nil }
            let result = format(value)
            return Answer(expression: text, result: result, display: result)
        }

        // MARK: Numbers

        /// Up to ten significant digits, no trailing zeros, no exponent for
        /// everyday sizes.
        static func format(_ value: Double) -> String {
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

        /// Recursive descent: + - over * / % over unary minus over ^ over
        /// numbers, parentheses, `pi`, `e` and `sqrt(…)`.
        struct Parser {
            private let characters: [Character]
            private var index = 0
            private(set) var sawOperator = false

            init(_ text: String) {
                characters = Array(text.lowercased())
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
                while let sign = take(["+", "-", "−"]) {
                    sawOperator = true
                    guard let next = product() else { return nil }
                    value = sign == "+" ? value + next : value - next
                }
                return value
            }

            private mutating func product() -> Double? {
                guard var value = unary() else { return nil }
                while true {
                    if take(["%"]) != nil {
                        // `15%` alone is 0.15; `10 % 3` would read as a modulo
                        // nobody types here, so % is always a percent.
                        sawOperator = true
                        value /= 100
                        continue
                    }
                    guard let sign = take(["*", "/", "×", "÷", "x"]) else { return value }
                    sawOperator = true
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
                return number()
            }

            private mutating func word(_ name: String) -> Bool {
                skipSpaces()
                let letters = Array(name)
                guard index + letters.count <= characters.count, Array(characters[index..<index + letters.count]) == letters else { return false }
                index += letters.count
                return true
            }

            private mutating func number() -> Double? {
                let start = index
                while index < characters.count, characters[index].isNumber || characters[index] == "." || characters[index] == "," {
                    index += 1
                }
                let digits = String(characters[start..<index]).replacingOccurrences(of: ",", with: "")
                return digits.isEmpty ? nil : Double(digits)
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
            guard let amount = parser.parse(), amount.isFinite else { return nil }
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
    }
}
