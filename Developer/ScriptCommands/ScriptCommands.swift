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
    nonisolated static let folder = "~/Script Commands"
    static let interpreters = ["bash", "zsh", "sh", "python3", "node", "ruby", "perl", "php", "swift", "osascript"]

    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.script-commands",
        name: "Script Commands",
        version: "1.4.0",
        summary: "Run your own scripts from the palette, in Raycast's Script Commands format.",
        surfaces: [.panel, .settings],
        // Every minute for inline scripts that refresh; the folders are
        // read again every 5 minutes.
        triggers: [.launch, .every(.seconds(60))],
        capabilities: [
            .files(paths: [folder]),
            .run(commands: ["grep"] + interpreters),
        ],
        minimumStackbar: "0.35.0",
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
        PreviewScene("first-run", "Start with one line in a script") { plugin in
            plugin.scripts = []
            plugin.scanned = true
        },
    ]

    let theme = Theme.graphite

    struct Script: Equatable, Identifiable {
        enum Mode: String { case silent, compact, fullOutput, inline }
        struct Argument: Equatable {
            /// One entry of a dropdown: what the palette shows, and what the script gets.
            struct Choice: Equatable { var title: String; var value: String }
            var placeholder: String
            var optional: Bool
            var secure = false
            var choices: [Choice] = []
        }

        /// Relative to its folder: `./uuid.py`.
        var file: String
        /// The folder it is in: ~/Script Commands, or one the user added.
        var folder: String = ScriptCommands.folder
        var interpreter: String?
        var title: String
        var mode: Mode = .compact
        var package: String?
        var icon: String?
        var description: String?
        var arguments: [Argument] = []
        var needsConfirmation = false
        /// How often an inline script runs again, in seconds (`@raycast.refreshTime`).
        var refreshTime: TimeInterval?

        var id: String {
            // Stable across launches: the command id is the file name, with
            // an added folder's name in front.
            let prefix = folder == ScriptCommands.folder ? "" : (folder as NSString).lastPathComponent + "-"
            let id = "script-" + (prefix + file.dropFirst(2)).map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined().lowercased()
            return String(id.prefix(64))
        }
        var name: String { String(file.dropFirst(2)) }
    }

    var scripts: [Script] = []
    var scanned = false
    var problem: String?
    /// The last full output, by script id, for the fullOutput view.
    var outputs: [String: String] = [:]
    /// An inline script's last line, by id, and when it ran.
    var inline: [String: (line: String, at: Date)] = [:]
    /// Folders the user added in Settings, besides ~/Script Commands.
    var added: [String] = []

    // MARK: Reading the folder

    func refresh() async throws {
        if Date().timeIntervalSince(lastScan) >= Self.rescanAfter { await scan() }
        await refreshInline()
    }

    static let rescanAfter: TimeInterval = 290

    /// A path with the home folder as ~.
    static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// `10s`, `5m`, `1h`, `1d`: Raycast's refresh times, at least a minute
    /// here, since that is how often Stackbar looks.
    nonisolated static func refreshTime(_ text: String) -> TimeInterval? {
        let text = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let unit = text.last, let count = Double(text.dropLast()), count > 0 else { return nil }
        let seconds: Double
        switch unit {
        case "s": seconds = count
        case "m": seconds = count * 60
        case "h": seconds = count * 3600
        case "d": seconds = count * 86400
        default: return nil
        }
        return max(seconds, 60)
    }

    /// Runs the inline scripts that are due, one at a time, and keeps their
    /// last line for the palette.
    func refreshInline(now: Date = Date()) async {
        for script in scripts where script.mode == .inline {
            guard let every = script.refreshTime, script.arguments.allSatisfy(\.optional) else { continue }
            if let last = inline[script.id], now.timeIntervalSince(last.at) < every - 5 { continue }
            guard let result = try? await run(script, arguments: script.arguments.map { _ in "" }) else { continue }
            let line = Self.lastLine(result.succeeded ? result.text : result.errorText) ?? (result.succeeded ? "" : "failed (\(result.status))")
            inline[script.id] = (line, Date())
        }
    }

    /// Adds a folder of scripts, chosen by the user.
    func addFolder() async throws {
        guard try await Stackbar.chooseFolder(prompt: "Choose a folder of script commands") != nil else { return }
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
        added = ((try? await Stackbar.grantedFolders()) ?? []).filter { $0 != Self.folder }
        var found: [Script] = []
        for folder in added {
            // An added folder that can't be read is skipped; the main one says why.
            guard let result = try? await Stackbar.run("grep", Self.grepArguments, workingDirectory: folder, timeout: .seconds(10)),
                  Self.usable(status: result.status, timedOut: result.timedOut, hasOutput: !result.stdout.isEmpty) else { continue }
            found += Self.parse(result.text, folder: folder)
        }
        do {
            // Every metadata line and every shebang, as ./file:line.
            let result = try await Stackbar.run("grep", Self.grepArguments, workingDirectory: Self.folder, timeout: .seconds(10))
            guard Self.usable(status: result.status, timedOut: result.timedOut, hasOutput: !result.stdout.isEmpty) else {
                // Keep the list from the last good scan.
                problem = result.timedOut ? "Reading the Script Commands folder took too long." : result.errorText.isEmpty ? "grep failed (\(result.status))" : String(result.errorText.prefix(200))
                scanned = true
                return
            }
            scripts = Self.parse(result.text) + found
            problem = nil
        } catch {
            let text = "\(error)"
            problem = text.contains("not a folder") || text.contains("exist") || text.contains("No such")
                ? "Make a folder named Script Commands in your home folder and put your scripts in it."
                : text
            // A folder that is gone has no scripts; any other failure (a
            // timeout, say) keeps the last good list.
            if text.contains("not a folder") || text.contains("exist") || text.contains("No such") { scripts = found }
        }
        scanned = true
    }

    /// `grep -H` output, `./file:line`, into one script a file with a title.
    nonisolated static func parse(_ output: String, folder: String = ScriptCommands.folder) -> [Script] {
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
            var script = Script(file: file, folder: folder, title: "")
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
                case "refreshTime": script.refreshTime = refreshTime(value)
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
    nonisolated static func interpreter(fromShebang line: String) -> String? {
        let parts = line.dropFirst(2).split(separator: " ").map(String.init).filter { $0 != "-S" }
        guard let first = parts.first else { return nil }
        let program = (first as NSString).lastPathComponent
        if program == "env" { return parts.dropFirst().first { !$0.hasPrefix("-") }.map { ($0 as NSString).lastPathComponent } }
        return program
    }

    /// `{ "type": "text", "placeholder": "City", "optional": true }`. A dropdown's
    /// choices are read one at a time: a choice that doesn't decode is skipped,
    /// and choices that can't be read at all leave a free-text argument.
    nonisolated static func argument(_ json: String) -> Script.Argument? {
        struct Item: Decodable { var title: String; var value: String }
        struct LossyItem: Decodable {
            let value: Item?
            init(from decoder: Decoder) throws { value = try? Item(from: decoder) }
        }
        struct Spec: Decodable {
            enum Key: String, CodingKey { case type, placeholder, optional, secure, data }
            var type: String?; var placeholder: String?; var optional: Bool?; var secure: Bool?; var data: [Item]?
            init(from decoder: Decoder) throws {
                let fields = try decoder.container(keyedBy: Key.self)
                type = try fields.decodeIfPresent(String.self, forKey: .type)
                placeholder = try fields.decodeIfPresent(String.self, forKey: .placeholder)
                optional = try fields.decodeIfPresent(Bool.self, forKey: .optional)
                secure = try fields.decodeIfPresent(Bool.self, forKey: .secure)
                let choices = try? fields.decodeIfPresent([LossyItem].self, forKey: .data)
                data = choices?.compactMap(\.value)
            }
        }
        guard let data = json.data(using: .utf8), let spec = try? JSONDecoder().decode(Spec.self, from: data) else { return nil }
        return Script.Argument(placeholder: spec.placeholder ?? "Argument", optional: spec.optional ?? false, secure: spec.secure ?? (spec.type == "password"),
                               choices: spec.data?.map { Script.Argument.Choice(title: $0.title, value: $0.value) } ?? [])
    }

    // MARK: Running

    /// The interpreter a script runs with, or why it can't run.
    static func interpreter(for script: Script) throws -> String {
        guard let interpreter = script.interpreter else {
            throw HostError("\(script.name) has no #! line naming its interpreter")
        }
        guard interpreters.contains(interpreter) else {
            throw HostError("\(script.name) runs with \(interpreter); Script Commands runs \(interpreters.joined(separator: ", "))")
        }
        return interpreter
    }

    func run(_ script: Script, arguments: [String]) async throws -> RunResult {
        let interpreter = try Self.interpreter(for: script)
        // Ten minutes, as long as Stackbar lets a command take.
        return try await Stackbar.run(interpreter, [script.file] + arguments, workingDirectory: script.folder, timeout: .seconds(600))
    }

    /// Runs a script for a row or a palette command: whether it worked, and
    /// what to say about it. A silent script shows its last line as a HUD.
    func perform(_ script: Script, arguments: [String]) async throws -> (ok: Bool, message: String?) {
        let result = try await run(script, arguments: arguments)
        if script.mode == .fullOutput { outputs[script.id] = Self.shownOutput(result) }
        guard result.succeeded else {
            return (false, "\(script.title) failed (\(result.status))" + (Self.lastLine(result.errorText).map { ": \($0)" } ?? ""))
        }
        let last = Self.lastLine(result.text)
        if script.mode == .silent {
            if let last { Stackbar.hud(last) }
            return (true, nil)
        }
        if script.mode == .inline { inline[script.id] = (last ?? "", Date()) }
        return (true, last ?? "\(script.title) done")
    }

    static func lastLine(_ text: String) -> String? {
        text.split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }
    }

    /// What a full-output view shows: the output, with the exit status on top
    /// when the script failed.
    static func shownOutput(_ result: RunResult) -> String {
        var text = result.text + (result.errorText.isEmpty ? "" : "\n" + result.errorText)
        if !result.succeeded { text = "Exited with status \(result.status)\n" + text }
        return text.isEmpty ? "(no output, exit \(result.status))" : String(text.prefix(20_000))
    }

    /// The arguments the script gets. A dropdown's title becomes its value.
    func values(_ script: Script, from invocation: CommandInvocation) -> [String] {
        script.arguments.enumerated().map { index, argument in
            let typed = invocation["argument\(index + 1)"] ?? ""
            return argument.choices.first { $0.title == typed }?.value ?? typed
        }
    }

    func command(for script: Script) -> Command {
        // An inline script shows what it last printed, as in Raycast.
        let shown = script.mode == .inline ? inline[script.id].map(\.line).flatMap { $0.isEmpty ? nil : $0 } : nil
        let subtitle = shown ?? [script.package, script.description].compactMap { $0 }.joined(separator: " · ")
        var command: Command
        if script.mode == .fullOutput || script.needsConfirmation {
            command = Command(script.id, title: script.title, subtitle: subtitle.isEmpty ? script.name : subtitle, symbol: "terminal", keywords: ["script", script.package ?? ""].filter { !$0.isEmpty })
                .view { invocation in self.outputView(script, arguments: self.values(script, from: invocation)) }
        } else {
            command = Command(script.id, title: script.title, subtitle: subtitle.isEmpty ? script.name : subtitle, symbol: "terminal", keywords: ["script", script.package ?? ""].filter { !$0.isEmpty }) { invocation in
                let (ok, message) = try await self.perform(script, arguments: self.values(script, from: invocation))
                return ok ? .message(message) : .failure(message ?? "")
            }
        }
        // As long as the script may run (Stackbar 0.36; older ones stop at 30 s).
        command = command.timeout(.seconds(600))
        for (index, argument) in script.arguments.enumerated() {
            command = command.argument("argument\(index + 1)", placeholder: argument.placeholder, required: !argument.optional,
                                       options: argument.choices.isEmpty ? nil : argument.choices.map(\.title))
        }
        return command
    }

    /// A script whose mode is fullOutput, or that asks first: one row to run
    /// it, then what it printed.
    @ViewBuilder func outputView(_ script: Script, arguments: [String]) -> ViewContent {
        List {
            Row(outputs[script.id] == nil ? "Run \(script.title)" : "Run Again", subtitle: script.needsConfirmation ? "This script asks before it runs" : script.name, symbol: "play.fill", key: "run")
                .action("Run Script", role: script.needsConfirmation ? .critical : .primary, confirm: .none) {
                    do {
                        self.outputs[script.id] = Self.shownOutput(try await self.run(script, arguments: arguments))
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

    /// A script's row in the panel and in Script Commands. Return or a click
    /// runs it; Stackbar asks for a second press on one that asks first and
    /// can run (one that can't says why on the first press).
    func scriptRow(_ script: Script) -> Row {
        let runnable = (try? Self.interpreter(for: script)) != nil && !script.arguments.contains { !$0.optional }
        let confirm: Confirm = script.needsConfirmation && runnable ? "run \(script.title)" : .none
        return Row(script.title, subtitle: [script.package, script.name].compactMap { $0 }.joined(separator: " · "), symbol: "terminal", key: script.id)
            .badge(script.interpreter ?? "no #!", role: script.interpreter.map { Self.interpreters.contains($0) } == true ? .secondary : .critical)
            .action("Run", confirm: confirm) {
                _ = try Self.interpreter(for: script)
                if let missing = script.arguments.first(where: { !$0.optional }) {
                    throw HostError("\(script.title) needs \(missing.placeholder); run it from the palette")
                }
                let (ok, message) = try await self.perform(script, arguments: script.arguments.map { _ in "" })
                guard ok else { throw HostError(message ?? "") }
                if let message { Stackbar.hud(message) }
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
                    if script.mode == .fullOutput {
                        self.scriptRow(script).navigate("Show Output", to: script.id)
                    } else {
                        self.scriptRow(script)
                    }
                }
            }
        Command("reload", title: "Reload Script Commands", subtitle: ([Self.folder] + added.map(Self.tilde)).joined(separator: ", "), symbol: "arrow.clockwise", keywords: ["script", "reload", "refresh"]) { _ in
            await self.scan()
            if let problem = self.problem { return .failure(problem) }
            return .message("\(self.scripts.count) script command\(self.scripts.count == 1 ? "" : "s")")
        }
    }

    // MARK: Panel

    var panel: ViewContent {
        PanelHeader("Script Commands", subtitle: "\(scripts.count) in \(Self.folder)" + (added.isEmpty ? "" : " and \(added.count) more folder\(added.count == 1 ? "" : "s")"), symbol: "terminal.fill", theme: theme)
        if let problem, !scripts.isEmpty {
            Banner(problem, theme: .warning)
        }
        if scripts.isEmpty {
            // With no folder, the problem already says what to do, so it is the one message.
            EmptyState("Add your first script", symbol: "terminal", message: problem ?? "Put a script with a \"# @raycast.title My Command\" line in ~/Script Commands, and it shows up in the palette within a minute. Raycast's script-commands repository on GitHub has hundreds ready to copy.", theme: theme)
        } else {
            List(scripts, searchable: scripts.count > 8) { script in self.scriptRow(script) }
        }
    }

    // MARK: Settings

    var settings: ViewContent {
        Section("Folders") {
            LabeledContent("Always", value: Self.folder)
            for folder in added {
                LabeledContent("Added", value: Self.tilde(folder))
            }
            Button("Add a Folder…", symbol: "folder.badge.plus") { try await self.addFolder() }
            Text("Scripts in an added folder become commands too. Remove a folder under Folders you chose, below.").style(.caption)
        }
    }
}
