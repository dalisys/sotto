import Foundation
import CoreGraphics

struct ShortcutKey: Codable, Equatable, Hashable, Identifiable {
    var code: UInt16
    var name: String
    var id: UInt16 { code }
    var isModifier: Bool { Self.modifierCodes.contains(code) }
    static let modifierCodes: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62, 63]
    static func modifiers(in flags: CGEventFlags, preserving keys: Set<UInt16>) -> Set<UInt16> {
        var result: Set<UInt16> = []
        let groups: [(CGEventFlags, Set<UInt16>, UInt16)] = [(.maskCommand, [54, 55], 55),
            (.maskShift, [56, 60], 56), (.maskAlternate, [58, 61], 58),
            (.maskControl, [59, 62], 59), (.maskSecondaryFn, [63], 63)]
        for (mask, group, fallback) in groups where flags.contains(mask) {
            let physical = keys.intersection(group)
            result.formUnion(physical.isEmpty ? [fallback] : physical)
        }
        return result
    }
    static func modifierIsDown(code: UInt16, flags: CGEventFlags, held: Set<UInt16>) -> Bool {
        let mask: CGEventFlags
        switch code {
        case 54, 55: mask = .maskCommand
        case 56, 60: mask = .maskShift
        case 58, 61: mask = .maskAlternate
        case 59, 62: mask = .maskControl
        case 63: mask = .maskSecondaryFn
        default: return false
        }
        // The event carries the new group state; the physical key code identifies
        // which side changed. Track each side to handle releasing one of two held modifiers.
        return flags.contains(mask) && !held.contains(code)
    }
    static func label(code: UInt16, characters: String? = nil) -> String {
        let special: [UInt16: String] = [36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
            54: "Right ⌘", 55: "⌘", 56: "⇧", 57: "Caps Lock", 58: "⌥", 59: "⌃", 60: "Right ⇧",
            61: "Right ⌥", 62: "Right ⌃", 63: "Fn", 64: "F17", 71: "Clear", 76: "Enter",
            79: "F18", 80: "F19", 90: "F20", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
            101: "F9", 103: "F11", 105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12",
            113: "F15", 114: "Help", 115: "Home", 116: "Page Up", 117: "Forward Delete", 118: "F4",
            119: "End", 120: "F2", 121: "Page Down", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        if let name = special[code] { return name }
        if let characters, !characters.isEmpty,
           characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            return String(characters.prefix(12)).uppercased()
        }
        return "Key \(code)"
    }
}

struct SottoShortcut: Codable, Equatable {
    var keys: [ShortcutKey]
    static let defaultShortcut = SottoShortcut(keys: [.init(code: 59, name: "⌃"), .init(code: 58, name: "⌥"), .init(code: 49, name: "Space")])
    var title: String { keys.map(\.name).joined(separator: " + ") }
    var compactTitle: String { keys.map(\.name).joined(separator: " ") }
    var codes: Set<UInt16> { Set(keys.map(\.code)) }
    var isValid: Bool { !keys.isEmpty && keys.count <= 8 && codes.count == keys.count && keys.allSatisfy { $0.code < 128 } }
    init(keys: [ShortcutKey]) { self.keys = keys }

    init(from decoder: Decoder) throws {
        if let old = try? decoder.singleValueContainer().decode(String.self) {
            switch old {
            case "controlOptionSpace": self = .defaultShortcut
            case "controlShiftSpace": self.init(keys: [.init(code: 59, name: "⌃"), .init(code: 56, name: "⇧"), .init(code: 49, name: "Space")])
            case "commandShiftSpace": self.init(keys: [.init(code: 55, name: "⌘"), .init(code: 56, name: "⇧"), .init(code: 49, name: "Space")])
            default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown legacy shortcut"))
            }
        } else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(keys: try container.decode([ShortcutKey].self, forKey: .keys))
        }
        guard isValid else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Shortcut must contain one to eight distinct keys")) }
    }
    private enum CodingKeys: String, CodingKey { case keys }
}

/// Tracks only physical key codes. A matching chord fires once until released.
/// Regular-key prefixes are buffered briefly by the service, so A+B does not type A first.
struct ShortcutChordMatcher {
    struct Decision {
        var fire = false
        var buffer = false
        var suppress = false
        var flush = false
        var discard = false
    }
    let target: Set<UInt16>
    private(set) var pressed: Set<UInt16> = []
    private var swallowed: Set<UInt16> = []
    private var buffered: Set<UInt16> = []
    private var fired = false
    private var prefixPassed = false

    init(target: Set<UInt16>, initiallyPressed: Set<UInt16> = []) {
        self.target = target
        pressed = initiallyPressed
        prefixPassed = !initiallyPressed.intersection(target).isEmpty
    }

    mutating func process(code: UInt16, down: Bool, repeated: Bool = false) -> Decision {
        var result = Decision()
        let modifier = ShortcutKey.modifierCodes.contains(code)
        if down {
            pressed.insert(code)
            if repeated {
                result.suppress = swallowed.contains(code) || buffered.contains(code)
                return result
            }
            if pressed == target && !fired && !prefixPassed {
                fired = true
                swallowed.formUnion(target.subtracting(ShortcutKey.modifierCodes))
                buffered.removeAll()
                result.fire = true
                result.discard = true
                result.suppress = !modifier
            } else if target.contains(code) && pressed.isSubset(of: target) && !prefixPassed && !fired && !modifier {
                buffered.insert(code)
                result.buffer = true
                result.suppress = true
            } else if !buffered.isEmpty && !pressed.isSubset(of: target) {
                buffered.removeAll()
                prefixPassed = true
                result.flush = true
            }
        } else {
            pressed.remove(code)
            if swallowed.remove(code) != nil { result.suppress = true }
            if buffered.contains(code) {
                buffered.removeAll()
                prefixPassed = true
                result.flush = true
            }
            if pressed.intersection(target).isEmpty {
                fired = false
                prefixPassed = false
            }
        }
        return result
    }

    mutating func expirePrefix() {
        if !buffered.isEmpty { buffered.removeAll(); prefixPassed = true }
    }
}
