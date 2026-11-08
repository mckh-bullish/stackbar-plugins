import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

/// Linear's API is `api.linear.app`, which the tests can't stand in for, so
/// these cover what happens before a request: no API key yet.
final class LinearTests: XCTestCase {
    /// Without an API key the menu bar stays quiet, not a warning, and the
    /// widget asks for the key.
    func testWithoutAKeyTheMenuBarStaysQuietAndTheWidgetAsksForOne() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Linear")
        let menu = await supervisor.views[.menuBar]
        guard case .label(_, _, let role)? = menu else { return XCTFail("the menu bar is a label: \(String(describing: menu))") }
        XCTAssertEqual(role, .secondary)
        let widget = await supervisor.views[.widget].map { TreeTextRenderer.render($0) } ?? ""
        XCTAssertTrue(widget.contains("Connect Linear"), widget)
        await supervisor.stop()
    }
}
