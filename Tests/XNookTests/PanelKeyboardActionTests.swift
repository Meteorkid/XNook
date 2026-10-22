import XCTest
@testable import XNook

final class PanelKeyboardActionTests: XCTestCase {
    func testNavigationAndQuickNoteKeys() {
        XCTAssertEqual(PanelKeyboardAction.resolve(characters: "0", modifiers: .command), .overview)
        XCTAssertEqual(PanelKeyboardAction.resolve(characters: "3", modifiers: .command), .tool(2))
        XCTAssertEqual(PanelKeyboardAction.resolve(characters: "n", modifiers: .command), .newNote)
        XCTAssertEqual(PanelKeyboardAction.resolve(characters: "s", modifiers: .command), .saveNote)
    }

    func testTypingAndEditorShortcutsAreNotIntercepted() {
        XCTAssertNil(PanelKeyboardAction.resolve(characters: "n", modifiers: []))
        XCTAssertNil(PanelKeyboardAction.resolve(characters: "z", modifiers: .command))
        XCTAssertNil(PanelKeyboardAction.resolve(characters: "3", modifiers: [.command, .shift]))
        XCTAssertNil(PanelKeyboardAction.resolve(characters: "n", modifiers: [.command, .option]))
    }
}
