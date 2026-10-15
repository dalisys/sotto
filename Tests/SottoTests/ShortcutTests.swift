import XCTest
@testable import Sotto

final class ShortcutTests: XCTestCase {
    func testModifierEventsUseEventFlagsAndTrackBothSides() {
        XCTAssertEqual(ShortcutKey.modifiers(in: [.maskControl, .maskAlternate], preserving: []), [59, 58])
        XCTAssertEqual(ShortcutKey.modifiers(in: .maskCommand, preserving: [54]), [54])
        XCTAssertTrue(ShortcutKey.modifierIsDown(code: 59, flags: .maskControl, held: []))
        XCTAssertFalse(ShortcutKey.modifierIsDown(code: 59, flags: [], held: [59]))
        XCTAssertTrue(ShortcutKey.modifierIsDown(code: 62, flags: .maskControl, held: [59]))
        XCTAssertFalse(ShortcutKey.modifierIsDown(code: 59, flags: .maskControl, held: [59, 62]))
        XCTAssertTrue(ShortcutKey.modifierIsDown(code: 63, flags: .maskSecondaryFn, held: []))
    }
    func testLegacyShortcutMigrationAndCustomRoundTrip() throws {
        let old = try JSONDecoder().decode(SottoShortcut.self, from: Data("\"controlOptionSpace\"".utf8))
        XCTAssertEqual(old, .defaultShortcut)
        for codes: [UInt16] in [[97], [58], [0, 11], [59, 58, 49]] {
            let shortcut = SottoShortcut(keys: codes.map { ShortcutKey(code: $0, name: ShortcutKey.label(code: $0)) })
            XCTAssertEqual(try JSONDecoder().decode(SottoShortcut.self, from: JSONEncoder().encode(shortcut)), shortcut)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(SottoShortcut.self, from: Data("{\"keys\":[]}".utf8)))
    }

    func testSingleKeyFiresOnceUntilReleasedAndConsumesRepeat() {
        var matcher = ShortcutChordMatcher(target: [97])
        XCTAssertTrue(matcher.process(code: 97, down: true).fire)
        let repeated = matcher.process(code: 97, down: true, repeated: true)
        XCTAssertFalse(repeated.fire)
        XCTAssertTrue(repeated.suppress)
        XCTAssertTrue(matcher.process(code: 97, down: false).suppress)
        XCTAssertTrue(matcher.process(code: 97, down: true).fire)
    }

    func testModifierOnlyShortcutAndThreeKeyChord() {
        var modifier = ShortcutChordMatcher(target: [58])
        XCTAssertTrue(modifier.process(code: 58, down: true).fire)
        XCTAssertFalse(modifier.process(code: 58, down: false).fire)
        XCTAssertTrue(modifier.process(code: 58, down: true).fire)
        var chord = ShortcutChordMatcher(target: [59, 58, 49])
        XCTAssertFalse(chord.process(code: 59, down: true).fire)
        XCTAssertFalse(chord.process(code: 58, down: true).fire)
        XCTAssertTrue(chord.process(code: 49, down: true).fire)
    }

    func testTwoOrdinaryKeysBufferPrefixAndConsumeBothReleases() {
        var chord = ShortcutChordMatcher(target: [0, 11])
        let prefix = chord.process(code: 0, down: true)
        XCTAssertTrue(prefix.buffer)
        XCTAssertTrue(prefix.suppress)
        let match = chord.process(code: 11, down: true)
        XCTAssertTrue(match.fire)
        XCTAssertTrue(match.discard)
        XCTAssertTrue(match.suppress)
        XCTAssertTrue(chord.process(code: 0, down: false).suppress)
        XCTAssertTrue(chord.process(code: 11, down: false).suppress)
        XCTAssertTrue(chord.process(code: 0, down: true).buffer)
        XCTAssertTrue(chord.process(code: 11, down: true).fire)
    }

    func testIncompleteChordReplaysNormalTypingAndLateChordDoesNotFire() {
        var chord = ShortcutChordMatcher(target: [0, 11])
        _ = chord.process(code: 0, down: true)
        let released = chord.process(code: 0, down: false)
        XCTAssertTrue(released.flush)
        XCTAssertFalse(released.suppress)
        _ = chord.process(code: 0, down: true)
        chord.expirePrefix()
        XCTAssertFalse(chord.process(code: 11, down: true).fire)
        XCTAssertFalse(chord.process(code: 11, down: false).suppress)
        _ = chord.process(code: 0, down: false)
        _ = chord.process(code: 11, down: true)
        XCTAssertTrue(chord.process(code: 0, down: true).fire)
    }

    func testUnexpectedExtraKeyFlushesPrefixAndPreventsActivation() {
        var chord = ShortcutChordMatcher(target: [0, 11])
        _ = chord.process(code: 0, down: true)
        XCTAssertTrue(chord.process(code: 2, down: true).flush)
        _ = chord.process(code: 2, down: false)
        XCTAssertFalse(chord.process(code: 11, down: true).fire)
    }

    func testHeldKeysAtRegistrationRequireReleaseBeforeActivation() {
        var chord = ShortcutChordMatcher(target: [58], initiallyPressed: [58])
        XCTAssertFalse(chord.process(code: 58, down: true).fire)
        _ = chord.process(code: 58, down: false)
        XCTAssertTrue(chord.process(code: 58, down: true).fire)
    }
}
