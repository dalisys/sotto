import AppKit
import XCTest
@testable import Sotto

final class FloatingBarTests: XCTestCase {
    func testHoverDoesNotMoveNativeCanvasOrBottomAnchor() {
        let visible = NSRect(x: 0, y: 25, width: 1440, height: 875)
        let frame = FloatingBarGeometry.frame(anchor: NSPoint(x: 720, y: 39), visible: visible)
        let small = FloatingBarGeometry.capsule(in: frame, size: FloatingBarGeometry.standby)
        let expanded = FloatingBarGeometry.capsule(in: frame, size: FloatingBarGeometry.expandedIdle)
        XCTAssertEqual(small.midX, expanded.midX)
        XCTAssertEqual(small.minY, expanded.minY)
        XCTAssertEqual(frame.size, FloatingBarGeometry.canvas)
        XCTAssertLessThan(small.width * small.height, 100 * 38 / 2)
    }

    func testPointerRemainsInsideWhileHoverExpandsAndTransparentCornersPassThrough() {
        let frame = NSRect(origin: .zero, size: FloatingBarGeometry.canvas)
        let small = FloatingBarGeometry.capsule(in: frame, size: FloatingBarGeometry.standby)
        let expanded = FloatingBarGeometry.capsule(in: frame, size: FloatingBarGeometry.expandedIdle)
        let pointer = NSPoint(x: small.midX, y: small.midY)
        XCTAssertTrue(FloatingBarGeometry.contains(pointer, capsule: small))
        XCTAssertTrue(FloatingBarGeometry.contains(pointer, capsule: expanded))
        XCTAssertFalse(FloatingBarGeometry.contains(NSPoint(x: small.minX + 1, y: small.minY + 1), capsule: small))
        XCTAssertFalse(FloatingBarGeometry.contains(NSPoint(x: frame.minX + 1, y: frame.maxY - 1), capsule: expanded))
    }

    func testBriefPointerExitDoesNotCollapseBarDuringHover() {
        var hover = FloatingBarHover()
        XCTAssertTrue(hover.update(inside: true, now: 0))
        XCTAssertTrue(hover.update(inside: false, now: 1))
        XCTAssertTrue(hover.update(inside: false, now: 1.1))
        XCTAssertTrue(hover.update(inside: true, now: 1.12))
        XCTAssertTrue(hover.update(inside: false, now: 2))
        XCTAssertFalse(hover.update(inside: false, now: 2.2))
    }

    func testRememberedDragPositionSurvivesSettingsAndDisconnectedDisplay() throws {
        var settings = UserSettings()
        settings.floatingBarPosition = FloatingBarPosition(x: -1500, y: 320)
        let restored = try JSONDecoder().decode(UserSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.floatingBarPosition, settings.floatingBarPosition)
        let visible = NSRect(x: 0, y: 25, width: 1440, height: 875)
        let frame = FloatingBarGeometry.frame(anchor: NSPoint(x: -1500, y: 320), visible: visible)
        XCTAssertTrue(visible.contains(FloatingBarGeometry.capsule(in: frame, size: FloatingBarGeometry.standby)))
        let oldSettings = try JSONDecoder().decode(UserSettings.self, from: Data("{}".utf8))
        XCTAssertNil(oldSettings.floatingBarPosition)
    }

    func testDragUsesLatestPointerPositionAndSavedAnchorDoesNotSnapBack() {
        let visible = NSRect(x: 0, y: 25, width: 1440, height: 875)
        let original = FloatingBarGeometry.frame(anchor: NSPoint(x: 720, y: 39), visible: visible)
        let drag = FloatingBarDrag(windowOrigin: original.origin, pointerOrigin: NSPoint(x: 710, y: 50))
        let moved = NSRect(origin: drag.origin(at: NSPoint(x: 420, y: 480)), size: original.size)
        let dropped = FloatingBarGeometry.capsule(in: moved, size: FloatingBarGeometry.standby)
        let restored = FloatingBarGeometry.frame(anchor: NSPoint(x: dropped.midX, y: dropped.minY), visible: visible)
        XCTAssertEqual(restored, moved)
        XCTAssertNotEqual(restored, original)
    }

    func testNearEdgeDropKeepsVisibleBarOnScreenWithoutMovingNativeFrameOnHover() {
        let visible = NSRect(x: 0, y: 25, width: 1440, height: 875)
        let frame = FloatingBarGeometry.frame(anchor: NSPoint(x: 34, y: 874), visible: visible)
        for size in [FloatingBarGeometry.standby, FloatingBarGeometry.expandedIdle, NSSize(width: 352, height: 68)] {
            let offset = FloatingBarGeometry.offset(frame: frame, size: size, visible: visible)
            let rect = FloatingBarGeometry.capsule(in: frame, size: size, offset: offset)
            XCTAssertTrue(visible.contains(rect))
            XCTAssertTrue(frame.contains(rect))
        }
        let small = FloatingBarGeometry.capsule(in: frame, size: FloatingBarGeometry.standby)
        XCTAssertEqual(small.midX, 34)
    }
}
