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
let stackbarRevision = "6996c7da4b3535c496ec80f673363b2024978332" // Stackbar 0.12.0 with custom styling, host timers and box shadows (#38)

/// Category folders. The folder name is the category the store shows.
let categories = ["System", "Developer", "Network", "Monitoring", "Productivity"]

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let plugins: [(category: String, name: String)] = categories.flatMap { category in
    let folder = root.appendingPathComponent(category, isDirectory: true)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return names.sorted().filter { name in
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).appendingPathComponent("\(name).swift").path)
    }.map { (category, $0) }
}

let stackbar: Package.Dependency = ProcessInfo.processInfo.environment["STACKBAR_PATH"].map { .package(name: "stackbar", path: $0) }
    ?? .package(url: "https://github.com/navbytes/stackbar", revision: stackbarRevision)

let package = Package(
    name: "stackbar-plugins",
    platforms: [.macOS("26.0")],
    dependencies: [stackbar],
    targets: plugins.map { plugin in
        // A prefix keeps plugin target names clear of stackbar's own targets.
        .executableTarget(
            name: "Plugin_\(plugin.name)",
            dependencies: [.product(name: "StackbarKit", package: "stackbar")],
            path: "\(plugin.category)/\(plugin.name)",
            exclude: ["README.md"]
        )
    }
)
