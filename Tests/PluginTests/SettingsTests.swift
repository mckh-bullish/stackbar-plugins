import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

final class SettingsTests: XCTestCase {
    /// Preferences set once live on the settings surface, not in the panel
    /// (CONTRIBUTING.md, rule 5).
    func testPreferencesStayOutOfThePanel() async throws {
        for name in ["Clipboard", "PRCockpit", "StayAwake", "UpNext"] {
            let supervisor = try await Host(self).start(name)
            XCTAssertTrue(supervisor.manifest.surfaces.contains(.settings), name)
            let panel = Set(await supervisor.views[.panel]?.actions ?? [])
            let preferences = await supervisor.views[.settings]?.toggles ?? []
            XCTAssertFalse(preferences.isEmpty, "\(name) has preferences in settings")
            for preference in preferences {
                XCTAssertFalse(panel.contains(preference.action), "\(name)'s panel still has \(preference.title)")
            }
            await supervisor.stop()
        }
    }
}
