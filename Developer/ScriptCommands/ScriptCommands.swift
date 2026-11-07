import StackbarKit
import Foundation

/// Your own scripts as palette commands, in the format Raycast's Script
/// Commands use, so the scripts you already have (and the hundreds in
/// raycast/script-commands on GitHub) work as they are.
///
/// Put scripts in ~/Script Commands. Each one with a `@raycast.title` line
/// becomes a command; its arguments, mode and icon come from the other
/// `@raycast.` lines. Stackbar runs it with the interpreter its first line
/// names (bash, zsh, python3, node, ruby, swift, osascript and a few more).
@main
final class ScriptCommands: StackbarPlugin {
    static let folder = "~/Script Commands"
    static let interpreters = ["bash", "zsh", "sh", "python3", "node", "ruby", "perl", "php", "swift", "osascript"]

    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.script-commands",
        name: "Script Commands",
        version: "1.1.0",
        summary: "Run your own scripts from the palette, in Raycast's Script Commands format.",
        surfaces: [.panel],
        triggers: [.launch, .every(.seconds(300))],
        capabilities: [
            .files(paths: [folder]),
            .run(commands: ["grep"] + interpreters),
        ],
        minimumStackbar: "0.22.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Developer/ScriptCommands",
        accent: .graphite,
        symbol: "terminal.fill"
    )

    static let previews: [PreviewScene<ScriptCommands>] = [
        PreviewScene("hero", "Your scripts, as commands") { plugin in
            plugin.scripts = [
                Script(file: "./git-pull-all.sh", interpreter: "bash", title: "Pull All Repos", mode: .compact, package: "Developer", icon: "🔄"),
                Script(file: "./uuid.py", interpreter: "python3", title: "Copy New UUID", mode: .silent, package: "Utilities", icon: "🆔"),
                Script(file: "./weather.sh", interpreter: "bash", title: "Weather", mode: .fullOutput, package: "Utilities", icon: "⛅️",
                       arguments: [Script.Argument(placeholder: "City", optional: true)]),
            ]
            plugin.scanned = true
        },
    ]

    let theme = Theme.graphite

    struct Script: Equatable, Identifiable {
        enum Mode: String { case silent, compact, fullOutput, inline }
        struct Argument: Equatable {
            var placeholder: String
            var optional: Bool
            var secure = false
        }

        /// Relative to the folder: `./uuid.py`.
        var file: String
        var interpreter: String?
        var title: String
        var mode: Mode = .compact
        var package: String?
        var icon: String?
        var description: String?
        var arguments: [Argument] = []
        var needsConfirmation = false

        var id: String {
            // Stable across launches: the command id is the file name.
            "script-" + file.dropFirst(2).map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined().lowercased()
        }
        var name: String { String(file.dropFirst(2)) }
    }

    var scripts: [Script] = []
    var scanned = false
    var problem: String?
    /// The last full output, by script id, for the fullOutput view.
    var outputs: [String: String] = [:]

    // MARK: Reading the folder

    func refresh() async throws {
        await scan()
    }

    /// Folders that hold other people's code, never scripts of yours: a
    /// cloned repository or a package install would be read in full.
    static let skippedFolders = [".git", ".hg", ".svn", "node_modules", ".build", "__pycache__", ".venv", "venv", "Pods", "DerivedData"]

    static var grepArguments: [String] {
        ["-r", "-I", "-H", "-E"] + skippedFolders.map { "--exclude-dir=\($0)" } + ["^#!|@raycast\\.[a-zA-Z0-9]+ ", "."]
    }

    /// Whether grep's answer can be used: it exits 1 when nothing matches (an
    /// empty folder) and 2 when some file or folder was unreadable, even
    /// though it printed every match it could read.
    static func usable(status: Int32, timedOut: Bool, hasOutput: Bool) -> Bool {
        guard !timedOut else { return false }
        return status == 0 || status == 1 || (status == 2 && hasOutput)
    }

    private var lastScan = Date.distantPast
    /// Opening the Script Commands view rescans unless a scan just ran.
    static let openRescanAfter: TimeInterval = 5

    func scan() async {
        defer { lastScan = Date() }
        do {
            // Every metadata line and every shebang, as ./file:line.
            let result = try await Stackbar.run("grep", Self.grepArguments, workingDirectory: Self.folder, timeout: .seconds(10))
            guard Self.usable(status: result.status, timedOut: result.timedOut, hasOutput: !result.stdout.isEmpty) else {
                // Keep the list from the last good scan.
                problem = result.timedOut ? "Reading the Script Commands folder took too long." : result.errorText.isEmpty ? "grep failed (\(result.status))" : String(result.errorText.prefix(200))
                scanned = true
                return
            }
            scripts = Self.parse(result.text)
            problem = nil
        } catch {
            let text = "\(error)"
            problem = text.contains("not a folder") || text.contains("exist") || text.contains("No such")
                ? "Make a folder named Script Commands in your home folder and put your scripts in it."
                : text
            // A folder that is gone has no scripts; any other failure (a
            // timeout, say) keeps the last good list.
            if text.contains("not a folder") || text.contains("exist") || text.contains("No such") { scripts = [] }
        }
        scanned = true
    }

    /// `grep -H` output, `./file:line`, into one script a file with a title.
    static func parse(_ output: String) -> [Script] {
        var order: [String] = []
        var lines: [String: [String]] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let file = String(line[..<colon])
            guard file.hasPrefix("./"), !file.contains("/."), !file.hasSuffix(".md") else { continue }
            if lines[file] == nil { order.append(file) }
            lines[file, default: []].append(String(line[line.index(after: colon)...]))
        }
        return order.compactMap { file in
            var script = Script(file: file, title: "")
            for line in lines[file] ?? [] {
                if line.hasPrefix("#!") {
                    if script.interpreter == nil { script.interpreter = interpreter(fromShebang: line) }
                    continue
                }
                guard let range = line.range(of: "@raycast.") else { continue }
                let rest = line[range.upperBound...]
                guard let space = rest.firstIndex(of: " ") else { continue }
                let key = String(rest[..<space])
                let value = rest[rest.index(after: space)...].trimmingCharacters(in: .whitespaces)
                switch key {
                case "title": script.title = value
                case "mode": script.mode = Script.Mode(rawValue: value) ?? .compact
                case "packageName": script.package = value
                case "icon": script.icon = value.count <= 2 ? value : nil
                case "description": script.description = value
                case "needsConfirmation": script.needsConfirmation = value == "true"
                case "argument1", "argument2", "argument3":
                    if let argument = argument(value) { script.arguments.append(argument) }
                default: break
                }
            }
            guard !script.title.isEmpty else { return nil }
            script.arguments = Array(script.arguments.prefix(3))
            return script
        }
        .sorted { ($0.package ?? "", $0.title) < ($1.package ?? "", $1.title) }
    }

    /// `#!/bin/bash`, `#!/usr/bin/env python3`, `#!/usr/bin/env -S node --flag`
    /// as the interpreter's name.
    static func interpreter(fromShebang line: String) -> String? {
        let parts = line.dropFirst(2).split(separator: " ").map(String.init).filter { $0 != "-S" }
        guard let first = parts.first else { return nil }
        let program = (first as NSString).lastPathComponent
        if program == "env" { return parts.dropFirst().first { !$0.hasPrefix("-") }.map { ($0 as NSString).lastPathComponent } }
        return program
    }

    /// `{ "type": "text", "placeholder": "City", "optional": true }`.
    static func argument(_ json: String) -> Script.Argument? {
        struct Spec: Decodable { var type: String?; var placeholder: String?; var optional: Bool?; var secure: Bool? }
        guard let data = json.data(using: .utf8), let spec = try? JSONDecoder().decode(Spec.self, from: data) else { return nil }
        return Script.Argument(placeholder: spec.placeholder ?? "Argument", optional: spec.optional ?? false, secure: spec.secure ?? (spec.type == "password"))
    }

    // MARK: Running

    func run(_ script: Script, arguments: [String]) async throws -> RunResult {
        guard let interpreter = script.interpreter else {
            throw HostError("\(script.name) has no #! line naming its interpreter")
        }
        guard Self.interpreters.contains(interpreter) else {
            throw HostError("\(script.name) runs with \(interpreter); Script Commands runs \(Self.interpreters.joined(separator: ", "))")
        }
        return try await Stackbar.run(interpreter, [script.file] + arguments, workingDirectory: Self.folder, timeout: .seconds(script.mode == .fullOutput ? 120 : 60))
    }

    static func lastLine(_ text: String) -> String? {
        text.split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }
    }

    func values(_ script: Script, from invocation: CommandInvocation) -> [String] {
        script.arguments.indices.map { invocation["argument\($0 + 1)"] ?? "" }
    }

    func command(for script: Script) -> Command {
        let subtitle = [script.package, script.description].compactMap { $0 }.joined(separator: " · ")
        var command: Command
        if script.mode == .fullOutput || script.needsConfirmation {
            command = Command(script.id, title: script.title, subtitle: subtitle.isEmpty ? script.name : subtitle, symbol: "terminal", keywords: ["script", script.package ?? ""].filter { !$0.isEmpty })
                .view { invocation in self.outputView(script, arguments: self.values(script, from: invocation)) }
        } else {
            command = Command(script.id, title: script.title, subtitle: subtitle.isEmpty ? script.name : subtitle, symbol: "terminal", keywords: ["script", script.package ?? ""].filter { !$0.isEmpty }) { invocation in
                let result = try await self.run(script, arguments: self.values(script, from: invocation))
                let last = Self.lastLine(result.text)
                guard result.succeeded else {
                    return .failure("\(script.title) failed (\(result.status))" + (Self.lastLine(result.errorText).map { ": \($0)" } ?? ""))
                }
                if script.mode == .silent, let last { Stackbar.hud(last) }
                return .message(script.mode == .silent ? nil : last ?? "\(script.title) done")
            }
        }
        for (index, argument) in script.arguments.enumerated() {
            command = command.argument("argument\(index + 1)", placeholder: argument.placeholder, required: !argument.optional)
        }
        return command
    }

    /// A script whose mode is fullOutput, or that asks first: one row to run
    /// it, then what it printed.
    @ViewBuilder func outputView(_ script: Script, arguments: [String]) -> ViewContent {
        List {
            Row(outputs[script.id] == nil ? "Run \(script.title)" : "Run Again", subtitle: script.needsConfirmation ? "This script asks before it runs" : script.name, symbol: "play.fill", key: "run")
                .action("Run Script", role: script.needsConfirmation ? .critical : .primary) {
                    do {
                        let result = try await self.run(script, arguments: arguments)
                        let text = result.text + (result.errorText.isEmpty ? "" : "\n" + result.errorText)
                        self.outputs[script.id] = text.isEmpty ? "(no output, exit \(result.status))" : String(text.prefix(20_000))
                    } catch {
                        self.outputs[script.id] = "\(error)"
                    }
                }
                .action("Copy Output", shortcut: "cmd+shift+c") { Stackbar.copy(self.outputs[script.id] ?? "") }
        }
        if let output = outputs[script.id] {
            Text(output).font(size: 12, design: .monospaced)
        }
    }

    // MARK: Commands

    var commands: [Command] {
        for script in scripts { command(for: script) }
        Command("scripts", title: "Script Commands", subtitle: "Your scripts; opening this looks for new ones", symbol: "terminal", keywords: ["script", "scripts", "list", "run"])
            .view(search: { _ in
                // Opening the view (and each keystroke after) picks up scripts
                // added since the last scan, without waiting for the timer.
                if Date().timeIntervalSince(self.lastScan) >= Self.openRescanAfter { await self.scan() }
            }) { _ in
                if let problem = self.problem { Banner(problem, theme: .warning) }
                List(self.scripts, searchable: true) { script in
                    Row(script.title, subtitle: [script.package, script.name].compactMap { $0 }.joined(separator: " · "), symbol: "terminal", key: script.id)
                        .badge(script.interpreter ?? "no #!", role: script.interpreter.map { Self.interpreters.contains($0) } == true ? .secondary : .critical)
                }
            }
        Command("reload", title: "Reload Script Commands", subtitle: Self.folder, symbol: "arrow.clockwise", keywords: ["script", "reload", "refresh"]) { _ in
            await self.scan()
            if let problem = self.problem { return .failure(problem) }
            return .message("\(self.scripts.count) script command\(self.scripts.count == 1 ? "" : "s")")
        }
    }

    // MARK: Panel

    var panel: ViewContent {
        PanelHeader("Script Commands", subtitle: "\(scripts.count) in \(Self.folder)", symbol: "terminal.fill", theme: theme)
        if let problem {
            Banner(problem, theme: .warning)
        }
        if scripts.isEmpty {
            EmptyState("Add your first script", symbol: "terminal", message: "Put a script with a \"# @raycast.title My Command\" line in ~/Script Commands, and it shows up in the palette within a minute. Raycast's script-commands repository on GitHub has hundreds ready to copy.", theme: theme)
        } else {
            Card("Your scripts", spacing: 0, padding: Space.s) {
                ForEach(scripts) { script in
                    Row(script.title, subtitle: [script.package, script.name].compactMap { $0 }.joined(separator: " · "), symbol: "terminal", key: script.id)
                        .badge(script.interpreter ?? "no #!", role: script.interpreter.map { Self.interpreters.contains($0) } == true ? .secondary : .critical)
                }
            }
        }
    }
}
