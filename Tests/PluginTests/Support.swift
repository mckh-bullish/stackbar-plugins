import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

/// Where SwiftPM put the plugin executables this test target depends on:
/// next to the .xctest bundle on macOS, next to the test binary elsewhere.
private let productsDirectory: URL = {
    #if os(macOS)
    if let bundle = Bundle.allBundles.first(where: { $0.bundlePath.hasSuffix(".xctest") }) {
        return bundle.bundleURL.deletingLastPathComponent()
    }
    #endif
    return URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
}()

/// A plugin's built executable, by its folder name (`UpNext`).
func plugin(_ name: String) -> URL { productsDirectory.appendingPathComponent("Plugin_\(name)") }

func waitUntil(_ timeout: Double = 15, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}

/// Collects what the host hands the platform (notifications, opened URLs,
/// copies), from any thread.
final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []
    var all: [Value] { lock.withLock { values } }
    func record(_ value: Value) { lock.withLock { values.append(value) } }
}

/// A simulated Mac and what the host passed to it, for one test.
struct Host {
    let system: SimulatedSystem
    let notifications = Recorder<HostNotification>()
    let alerts = Recorder<HostNotification>()
    let opened = Recorder<(url: String, app: String?)>()
    let copies = Recorder<String>()
    let services: HostServices

    init(_ test: XCTestCase, system: SimulatedSystem = SimulatedSystem()) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        self.system = system
        let (notifications, alerts, opened, copies) = (notifications, alerts, opened, copies)
        services = HostServices.local(directory: directory, secrets: MemorySecretStore([:]), platform: .init(
            notify: notifications.record,
            alert: alerts.record,
            open: { opened.record(($0.absoluteString, nil)) },
            openWith: { url, app in opened.record((url.absoluteString, app)) },
            copy: copies.record,
            system: system
        ))
    }

    /// Starts a plugin under a supervisor and waits for its first render.
    func start(_ name: String, policy: BackoffPolicy = .standard) async throws -> PluginSupervisor {
        let executable = plugin(name)
        let supervisor = PluginSupervisor(executable: executable, manifest: try PluginProcess.readManifest(executable: executable), policy: policy, services: services)
        await supervisor.start()
        _ = await waitUntil { await supervisor.settledCount >= supervisor.startupMessageCount }
        return supervisor
    }

    /// A plugin as the palette drives it: commands, views and forms.
    func session(_ name: String) async throws -> PluginSession {
        let session = PluginSession(source: plugin(name), loader: PluginLoader(builder: nil, sandbox: false), services: services)
        try await session.ensureRunning()
        return session
    }
}

extension PluginSupervisor {
    /// Sends an event and waits for the plugin to settle after it.
    nonisolated func press(_ action: ActionID, value: EventValue? = nil) async {
        let before = await settledCount
        await event(action, value: value)
        _ = await waitUntil { await self.settledCount > before }
    }
}

extension ViewNode {
    /// This node and everything below it, rows' accessories excepted.
    var tree: [ViewNode] { [self] + children.flatMap(\.tree) }

    /// Charts anywhere below, as (kind, values).
    var charts: [(kind: ChartKind, values: [Double])] {
        tree.compactMap { node in
            if case .chart(let values, let kind, _, _, _) = node { return (kind, values) }
            return nil
        }
    }

    /// The first form below, if any.
    var form: FormNode? {
        tree.lazy.compactMap { node in
            if case .form(let form) = node { return form }
            return nil
        }.first
    }

    /// Toggles anywhere below, as (title, action).
    var toggles: [(title: String, action: ActionID)] {
        tree.compactMap { node in
            if case .toggle(let title, _, let action) = node { return (title, action) }
            return nil
        }
    }
}

extension FormNode {
    /// Each field's error, by field name, for the fields that have one.
    var errors: [String: String] {
        Dictionary(uniqueKeysWithValues: fields.compactMap { field in field.error.map { (field.name, $0) } })
    }
}
