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

    func testAllowsControlShortcutsWithAdditionalModifiers() {
        let additionalModifiers: [CGEventFlags] = [.maskAlternate, .maskCommand, .maskShift]
        for modifier in additionalModifiers {
            let flags = modifier.union(.maskControl)
            XCTAssertFalse(blocksKey(124, flags: flags))
            XCTAssertFalse(blocksKey(18, flags: flags))
        }
    }

    func testBlocksControlArrowWithKeyClassificationFlags() {
        XCTAssertTrue(blocksKey(124, flags: [.maskControl, .maskAlphaShift, .maskNumericPad, .maskSecondaryFn]))
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

    func testEventTapLeavesScrollWheelEventsAlone() {
        let scrollWheelMask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
        XCTAssertEqual(FocusInputFilter.requiredKeyboardMask & scrollWheelMask, 0)
        XCTAssertEqual(FocusInputFilter.optionalInputMask & scrollWheelMask, 0)
    }

    func testTapInstallationFailsWhenOnlyOptionalEventsAreAvailable() {
        let keyDownMask = CGEventMask(1) << CGEventType.keyDown.rawValue
        var requestedMasks: [CGEventMask] = []

        let started = LockManager.installInputTaps { mask in
            requestedMasks.append(mask)
            return mask & ~keyDownMask != 0
        }

        XCTAssertFalse(started)
        XCTAssertEqual(requestedMasks, [keyDownMask])
    }

    func testTapInstallationAllowsKeyboardOnly() {
        let keyDownMask = CGEventMask(1) << CGEventType.keyDown.rawValue
        var requestedMasks: [CGEventMask] = []

        let started = LockManager.installInputTaps { mask in
            requestedMasks.append(mask)
            return mask == keyDownMask
        }

        XCTAssertTrue(started)
        XCTAssertEqual(requestedMasks, [keyDownMask, FocusInputFilter.optionalInputMask])
        XCTAssertEqual(FocusInputFilter.optionalInputMask & keyDownMask, 0)
    }

    func testPassingThroughOriginalEventDoesNotRetainIt() throws {
        let journal = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("settings.json")
        let gestures = SystemGestureSettings(preferences: TestGesturePreferences(values: [:]),
                                            journalURL: journal, activate: { true })
        let manager = LockManager(gestureSettings: gestures)
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        let retainCount = CFGetRetainCount(event)

        let passedThrough = manager.filterEvent(type: .keyDown, event: event)
        let retainCountAfterCallback = CFGetRetainCount(event)

        XCTAssertEqual(retainCountAfterCallback, retainCount)
        XCTAssertTrue(passedThrough?.takeUnretainedValue() === event)
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

    private func blocksTrackpadSwipe(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        FocusInputFilter.shouldBlockTrackpadSwipe(
            eventType: .swipe,
            deltaX: deltaX,
            deltaY: deltaY
        )
    }
}
