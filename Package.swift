// swift-tools-version: 6.2
// Every plugin in this repository as an executable target against StackbarKit,
// so `swift build` type-checks them all at once. A plugin is a folder
// <Category>/<Name>/ holding <Name>.swift; targets are found, not listed.
//
// StackbarKit comes from navbytes/stackbar at the pinned commit below. Set
// STACKBAR_PATH to a local checkout to build against it instead (the nightly
// canary does this with stackbar's main branch).
import Foundation
import PackageDescription

/// The Stackbar every plugin here builds against: a commit on stackbar's main
/// with commands, run, context, storage grants, heatmaps, user-chosen servers
/// and custom styling.
/// Switch to `exact:` once tags are pushed, and raise it in its own pull
/// request; a plugin may still set an older `minimumStackbar`.
let stackbarRevision = "28f399ec8d760cdbdf2b7cafbfcc69ec2b2d2c6f" // 0.31.0: rows kept out of the palette (#151)

/// Category folders. The folder name is the category the store shows.
let categories = ["System", "Developer", "Network", "Monitoring", "Productivity"]

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

/// The plugins in a folder: each subfolder holding `<Name>/<Name>.swift`.
func pluginNames(in folder: URL) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return names.sorted().filter { name in
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).appendingPathComponent("\(name).swift").path)
    }
}

/// Community plugins live one level deeper, under their author's GitHub
/// name: `Community/<user>/<Name>/<Name>.swift`. Their targets carry the
/// user too, so two authors can use the same name.
let communityUsers = ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Community").path)) ?? []).sorted()

let plugins: [(category: String, name: String, target: String)] = categories.flatMap { category in
    pluginNames(in: root.appendingPathComponent(category, isDirectory: true)).map { (category, $0, "Plugin_\($0)") }
} + communityUsers.flatMap { user in
    pluginNames(in: root.appendingPathComponent("Community/\(user)", isDirectory: true)).map { ("Community/\(user)", $0, "Plugin_\(user)_\($0)") }
}

/// The plugins Tests/PluginTests runs.
let testedPlugins = ["AppSwitcher", "Applications", "Calculator", "Clipboard", "ColorPicker", "Dictionary", "Emoji", "FileSearch", "Jira", "KillProcess", "Linear", "LiteLLM", "MenuSearch", "Music", "OpenRouter", "PRCockpit", "Pomodoro", "Ports", "Quicklinks", "RecentProjects", "Snippets", "StayAwake", "SystemCommands", "SystemMonitor", "Timers", "Todo", "Translate", "UpNext", "WindowSwitcher", "Windows", "WorldClock"]

let stackbar: Package.Dependency = ProcessInfo.processInfo.environment["STACKBAR_PATH"].map { .package(name: "stackbar", path: $0) }
    ?? .package(url: "https://github.com/navbytes/stackbar", revision: stackbarRevision)

let package = Package(
    name: "stackbar-plugins",
    platforms: [.macOS("26.0")],
    dependencies: [stackbar],
    targets: plugins.map { plugin in
        // A prefix keeps plugin target names clear of stackbar's own targets.
        .executableTarget(
            name: plugin.target,
            dependencies: [.product(name: "StackbarKit", package: "stackbar")],
            path: "\(plugin.category)/\(plugin.name)",
            exclude: ["README.md"]
        )
    } + [
        // Plugins' own behaviour, driven as real processes through
        // StackbarHostCore's supervisor over a simulated Mac. Depending on a
        // plugin builds its executable next to the tests.
        .testTarget(
            name: "PluginTests",
            dependencies: [
                .product(name: "StackbarHostCore", package: "stackbar"),
                .product(name: "StackbarProtocol", package: "stackbar"),
            ] + testedPlugins.map { .target(name: "Plugin_\($0)") },
            path: "Tests/PluginTests"
        ),
    ]
)
