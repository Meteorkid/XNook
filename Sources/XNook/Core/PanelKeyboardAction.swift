import AppKit

enum PanelKeyboardAction: Equatable {
    case overview
    case tool(Int)
    case newNote
    case saveNote

    static func resolve(characters: String?, modifiers: NSEvent.ModifierFlags) -> Self? {
        let relevant = modifiers.intersection([.command, .control, .option, .shift])
        guard relevant == .command else { return nil }
        switch characters?.lowercased() {
        case "0": return .overview
        case "1": return .tool(0)
        case "2": return .tool(1)
        case "3": return .tool(2)
        case "4": return .tool(3)
        case "n": return .newNote
        case "s": return .saveNote
        default: return nil
        }
    }
}
