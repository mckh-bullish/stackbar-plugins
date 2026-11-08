import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol
#if canImport(NaturalLanguage)
@testable import Plugin_Translate
#endif

/// Only the paths that stop before a translation service is called, so no
/// test sends text to Google or DeepL.
final class TranslateTests: XCTestCase {
    func testTranslateAndReplaceNeedsASelection() async throws {
        let host = Host(self)
        let session = try await host.session("Translate")
        let result = try await session.runCommand("translate-replace")
        XCTAssertEqual(result, .failure("Select some text first"))
        XCTAssertTrue(host.system.pasted.isEmpty, "nothing is pasted without a selection")
        await session.stop()
    }

    func testTranslateAndReplaceNeedsAnInPlaceEngine() async throws {
        let host = Host(self)
        try await host.services.storage.set("engine", "\"Browser\"", for: "io.navbytes.stackbar.plugins.translate")
        let session = try await host.session("Translate")
        let result = try await session.runCommand("translate-replace", context: InvocationContext(selectedText: "Guten Morgen"))
        XCTAssertEqual(result, .failure("Translate and Replace needs the Automatic or DeepL engine; change it in Settings"))
        XCTAssertTrue(host.system.pasted.isEmpty, "the browser engine never pastes")
        await session.stop()
    }

    #if canImport(NaturalLanguage)
    func testLocalLanguageReadsEnglish() async {
        let language = await Translate.localLanguage("Could you send me the signed contract by Friday?")
        XCTAssertEqual(language, "en")
    }
    #endif
}
