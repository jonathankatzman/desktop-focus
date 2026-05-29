import AppKit
import XCTest
@testable import DesktopFocus

final class FocusInputFilterTests: XCTestCase {
    func testBlocksControlArrowAndMissionControlShortcuts() {
        XCTAssertTrue(blocksKey(123, flags: .maskControl))
        XCTAssertTrue(blocksKey(124, flags: .maskControl))
        XCTAssertTrue(blocksKey(126, flags: .maskControl))
        XCTAssertTrue(blocksKey(125, flags: .maskControl))
    }

    func testBlocksControlNumberDesktopShortcuts() {
        for keyCode in FocusInputFilter.topRowDigitKeyCodes {
            XCTAssertTrue(blocksKey(keyCode, flags: .maskControl))
        }
    }

    func testAllowsOrdinaryKeyboardInput() {
        XCTAssertFalse(blocksKey(0, flags: []))
        XCTAssertFalse(blocksKey(123, flags: []))
        XCTAssertFalse(blocksKey(18, flags: []))
        XCTAssertFalse(blocksKey(124, flags: .maskCommand))
        XCTAssertFalse(
            FocusInputFilter.shouldBlockKeyboardShortcut(
                type: .keyUp,
                keyCode: 123,
                flags: .maskControl
            )
        )
    }

    func testBlocksMissionControlHardwareKey() {
        XCTAssertTrue(blocksKey(160, flags: []))
    }

    func testBlocksMissionControlAuxControlButtons() {
        XCTAssertTrue(blocksAuxControlButton(specialKeyCode: 32, keyState: 0x0A))
        XCTAssertTrue(blocksAuxControlButton(specialKeyCode: 33, keyState: 0x0A))
        XCTAssertTrue(blocksAuxControlButton(specialKeyCode: 34, keyState: 0x0A))
    }

    func testAllowsNonMissionControlAuxControlButtons() {
        XCTAssertFalse(blocksAuxControlButton(specialKeyCode: 0, keyState: 0x0A))
        XCTAssertFalse(blocksAuxControlButton(specialKeyCode: 16, keyState: 0x0A))
        XCTAssertFalse(blocksAuxControlButton(specialKeyCode: 32, keyState: 0x0B))
        XCTAssertFalse(
            FocusInputFilter.shouldBlockMissionControlButton(
                type: .keyDown,
                subtype: FocusInputFilter.auxControlButtonSubtype,
                data1: data1(specialKeyCode: 32, keyState: 0x0A)
            )
        )
    }

    func testBlocksDeliberateHorizontalGestureScroll() {
        XCTAssertTrue(
            blocksSwipe(
                horizontal: 8,
                vertical: 1,
                fixedHorizontal: 8.0,
                fixedVertical: 1.0,
                scrollPhase: 1
            )
        )
        XCTAssertTrue(
            blocksSwipe(
                horizontal: 0,
                vertical: 0,
                fixedHorizontal: -7.0,
                fixedVertical: 2.0,
                momentumPhase: 1
            )
        )
    }

    func testAllowsNormalScrollsAndSmallHorizontalMovement() {
        XCTAssertFalse(
            blocksSwipe(
                horizontal: 8,
                vertical: 1,
                fixedHorizontal: 8.0,
                fixedVertical: 1.0
            )
        )
        XCTAssertFalse(
            blocksSwipe(
                horizontal: 4,
                vertical: 1,
                fixedHorizontal: 4.0,
                fixedVertical: 1.0,
                scrollPhase: 1
            )
        )
        XCTAssertFalse(
            blocksSwipe(
                horizontal: 2,
                vertical: 10,
                fixedHorizontal: 2.0,
                fixedVertical: 10.0,
                scrollPhase: 1
            )
        )
        XCTAssertFalse(
            FocusInputFilter.shouldBlockSpaceSwipe(
                type: .keyDown,
                horizontal: 8,
                vertical: 1,
                fixedHorizontal: 8.0,
                fixedVertical: 1.0,
                scrollPhase: 1,
                momentumPhase: 0
            )
        )
    }

    func testBlocksHorizontalTrackpadSwipeGesture() {
        XCTAssertTrue(blocksTrackpadSwipe(deltaX: 1, deltaY: 0))
        XCTAssertTrue(blocksTrackpadSwipe(deltaX: -1, deltaY: 0))
        XCTAssertTrue(blocksTrackpadSwipe(deltaX: 1, deltaY: 0.25))
    }

    func testAllowsVerticalOrNonSwipeGestures() {
        XCTAssertFalse(blocksTrackpadSwipe(deltaX: 0, deltaY: 1))
        XCTAssertFalse(blocksTrackpadSwipe(deltaX: 0.25, deltaY: 1))
        XCTAssertFalse(
            FocusInputFilter.shouldBlockTrackpadSwipe(
                eventType: .scrollWheel,
                deltaX: 1,
                deltaY: 0
            )
        )
    }

    private func blocksKey(_ keyCode: Int, flags: CGEventFlags) -> Bool {
        FocusInputFilter.shouldBlockKeyboardShortcut(
            type: .keyDown,
            keyCode: keyCode,
            flags: flags
        )
    }

    private func blocksAuxControlButton(specialKeyCode: Int, keyState: Int) -> Bool {
        FocusInputFilter.shouldBlockMissionControlButton(
            type: systemDefinedEventType,
            subtype: FocusInputFilter.auxControlButtonSubtype,
            data1: data1(specialKeyCode: specialKeyCode, keyState: keyState)
        )
    }

    private func data1(specialKeyCode: Int, keyState: Int) -> Int {
        (specialKeyCode << 16) | (keyState << 8)
    }

    private func blocksSwipe(
        horizontal: Int64,
        vertical: Int64,
        fixedHorizontal: Double,
        fixedVertical: Double,
        scrollPhase: Int64 = 0,
        momentumPhase: Int64 = 0
    ) -> Bool {
        FocusInputFilter.shouldBlockSpaceSwipe(
            type: .scrollWheel,
            horizontal: horizontal,
            vertical: vertical,
            fixedHorizontal: fixedHorizontal,
            fixedVertical: fixedVertical,
            scrollPhase: scrollPhase,
            momentumPhase: momentumPhase
        )
    }

    private func blocksTrackpadSwipe(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        FocusInputFilter.shouldBlockTrackpadSwipe(
            eventType: .swipe,
            deltaX: deltaX,
            deltaY: deltaY
        )
    }
}
