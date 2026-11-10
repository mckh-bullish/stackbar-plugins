import XCTest
import StackbarHostCore
import StackbarProtocol

/// A temporary diagnostic for the Try Again retry: the host log, the panel
/// and gh's run log, tick by tick. Not part of the suite.
final class TryAgainProbeTests: XCTestCase {
    func testPressProbe() async throws {
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: bin) }
        let log = bin.appendingPathComponent("gh.log")
        let script = bin.appendingPathComponent("gh")
        try "#!/bin/sh\necho \"$*\" >> '\(log.path)'\nexit 1\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let gate = CommandRunGate(root: FileManager.default.temporaryDirectory.appendingPathComponent("stackbar-run-\(UUID().uuidString)", isDirectory: true),
                                  resolver: CommandResolver(directories: [bin.path]))
        let logs = Recorder<String>()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let platform = HostServices.Platform()
        let services = HostServices(storage: StorageStore(directory: directory.appendingPathComponent("storage", isDirectory: true)),
                                    secrets: MemorySecretStore([:]), platform: platform, runs: gate,
                                    folderGrants: FolderGrants(file: directory.appendingPathComponent("folder-grants.json")))
        let supervisor = PluginSupervisor(executable: plugin("PRCockpit"),
                                          manifest: try PluginProcess.readManifest(executable: plugin("PRCockpit")),
                                          policy: .standard, services: services,
                                          onUpdate: { update in
                                              if case .log(let level, let message) = update { logs.record("\(level): \(message)") }
                                          })
        await supervisor.start()
        await supervisor.grant([.network("api.github.com"), .secret(name: "GITHUB_TOKEN"), .run(commands: ["gh"]), .userServer(secret: "GITHUB_ENTERPRISE_URL")])
        let connected = await waitUntil { await supervisor.views[.panel].map { TreeTextRenderer.render($0) }?.contains("Connect to GitHub") == true }
        XCTAssertTrue(connected, "the panel starts in the connect state")

        // The Enterprise server: the loopback stub, no pasted token.
        try await hostServicesSet(services, "http://127.0.0.1:1", for: "GITHUB_ENTERPRISE_URL")
        try await hostServicesSet(services, "true", for: "enterprise")

        try "#!/bin/sh\nprintf GHSTUB\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        await supervisor.press(ActionID("button/Try Again"))
        for tick in 1...8 {
            try? await Task.sleep(for: .seconds(1))
            let text = await supervisor.views[.panel].map { TreeTextRenderer.render($0) } ?? "(none)"
            let runs = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").count
            let menu = await supervisor.views[.menuBar]?.plainText ?? "(none)"
            print("PROBE tick \(tick) menu \(menu) | gh runs \(runs) | \(text.prefix(150).replacingOccurrences(of: "\n", with: " / "))")
        }
        print("PROBE host log:")
        for line in logs.all.suffix(12) { print("  \(line)") }
        await supervisor.stop()
    }

    private func hostServicesSet(_ services: HostServices, _ value: String, for key: String) async throws {
        try await services.storage.set(key, value, for: "io.navbytes.stackbar.pr-cockpit")
        if key == "GITHUB_ENTERPRISE_URL" { try services.secrets.setSecret(value, for: key) }
    }
}
