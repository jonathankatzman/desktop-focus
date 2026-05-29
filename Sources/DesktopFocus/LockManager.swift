import AppKit
import Combine

// Free function required for CGEventTap C callback
private func tapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passRetained(event) }
    let manager = Unmanaged<LockManager>.fromOpaque(refcon).takeUnretainedValue()
    return manager.filterEvent(type: type, event: event)
}

let systemDefinedEventType = CGEventType(rawValue: 14)!
let swipeGestureEventType = CGEventType(rawValue: UInt32(NSEvent.EventType.swipe.rawValue))!

private func eventMask(_ type: CGEventType) -> CGEventMask {
    CGEventMask(1) << type.rawValue
}

struct FocusInputFilter {
    static let auxControlButtonSubtype = 8
    static let topRowDigitKeyCodes: Set<Int> = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]

    static func shouldBlockKeyboardShortcut(
        type: CGEventType,
        keyCode: Int,
        flags: CGEventFlags
    ) -> Bool {
        guard type == .keyDown else { return false }

        if flags.contains(.maskControl) {
            switch keyCode {
            case 123, 124: return true  // Ctrl+Left / Ctrl+Right — switch spaces
            case 126:      return true  // Ctrl+Up — Mission Control
            case 125:      return true  // Ctrl+Down — App Exposé
            default:
                // Ctrl+1 through Ctrl+0 can switch directly to numbered desktops.
                if topRowDigitKeyCodes.contains(keyCode) { return true }
            }
        }

        return keyCode == 160  // F3 / Mission Control hardware key
    }

    static func shouldBlockMissionControlButton(
        type: CGEventType,
        subtype: Int,
        data1: Int
    ) -> Bool {
        guard type == systemDefinedEventType,
              subtype == auxControlButtonSubtype else {
            return false
        }

        let specialKeyCode = (data1 & 0xFFFF0000) >> 16
        let keyState = (data1 & 0x0000FF00) >> 8
        let isKeyDown = keyState == 0x0A

        // Mission Control / Exposé special-key values vary across macOS and keyboards.
        // Blocking this small range avoids the brief Space animation for hardware keys
        // while leaving volume, brightness, playback, and eject keys alone.
        return isKeyDown && (32...34).contains(specialKeyCode)
    }

    static func shouldBlockSpaceSwipe(
        type: CGEventType,
        horizontal: Int64,
        vertical: Int64,
        fixedHorizontal: Double,
        fixedVertical: Double,
        scrollPhase: Int64,
        momentumPhase: Int64
    ) -> Bool {
        guard type == .scrollWheel else { return false }

        let isGestureLike = scrollPhase != 0 || momentumPhase != 0
        let isMostlyHorizontal = abs(horizontal) > abs(vertical)
            || abs(fixedHorizontal) > abs(fixedVertical)
        let isDeliberateSwipe = abs(horizontal) >= 6 || abs(fixedHorizontal) >= 6.0

        return isGestureLike && isMostlyHorizontal && isDeliberateSwipe
    }

    static func shouldBlockTrackpadSwipe(
        eventType: NSEvent.EventType,
        deltaX: CGFloat,
        deltaY: CGFloat
    ) -> Bool {
        guard eventType == .swipe else { return false }
        return abs(deltaX) > 0 && abs(deltaX) >= abs(deltaY)
    }
}

class LockManager: ObservableObject {
    @Published var isLocked = false
    @Published var timeRemaining: TimeInterval = 0
    @Published var unlockCode: String = ""
    @Published var penaltyCooldown: TimeInterval = 0

    var cancellables = Set<AnyCancellable>()

    private let systemGestureSettings = SystemGestureSettings()
    private var lockEndDate: Date?
    private var penaltyEndDate: Date?
    private var anchorWindow: NSWindow?
    private var spaceObserver: Any?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var localSwipeMonitor: Any?
    private var globalSwipeMonitor: Any?
    private var timer: Timer?
    private var wrongAttempts = 0

    func lock(duration: TimeInterval) {
        unlockCode = String(format: "%04d", Int.random(in: 0...9999))
        lockEndDate = Date().addingTimeInterval(duration)
        timeRemaining = duration
        wrongAttempts = 0
        penaltyCooldown = 0
        isLocked = true

        setupAnchorWindow()
        setupSpaceObserver()
        setupEventTap()
        setupSwipeMonitors()
        systemGestureSettings.suspendHorizontalSpaceSwipes()
        startTimer()
    }

    // Code is always valid regardless of time remaining — it's an escape hatch
    func attemptUnlock(code: String) -> Bool {
        guard penaltyCooldown <= 0 else { return false }
        guard code == unlockCode else {
            wrongAttempts += 1
            if wrongAttempts >= 3 {
                penaltyEndDate = Date().addingTimeInterval(60)
                penaltyCooldown = 60
                wrongAttempts = 0
            }
            return false
        }
        tearDown()
        return true
    }

    func forceUnlock() {
        tearDown()
    }

    // Called from the CGEventTap C callback
    func filterEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if system disabled it (e.g. after timeout)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passRetained(event)
        }

        guard isLocked else { return Unmanaged.passRetained(event) }

        if shouldBlockKeyboardShortcut(type: type, event: event) { return nil }
        if shouldBlockMissionControlButton(type: type, event: event) { return nil }
        if shouldBlockSpaceSwipe(type: type, event: event) { return nil }
        if shouldBlockTrackpadSwipe(type: type, event: event) { return nil }

        return Unmanaged.passRetained(event)
    }

    private func shouldBlockKeyboardShortcut(type: CGEventType, event: CGEvent) -> Bool {
        FocusInputFilter.shouldBlockKeyboardShortcut(
            type: type,
            keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
            flags: event.flags
        )
    }

    private func shouldBlockMissionControlButton(type: CGEventType, event: CGEvent) -> Bool {
        guard type == systemDefinedEventType,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == FocusInputFilter.auxControlButtonSubtype else {
            return false
        }

        return FocusInputFilter.shouldBlockMissionControlButton(
            type: type,
            subtype: Int(nsEvent.subtype.rawValue),
            data1: nsEvent.data1
        )
    }

    private func shouldBlockSpaceSwipe(type: CGEventType, event: CGEvent) -> Bool {
        FocusInputFilter.shouldBlockSpaceSwipe(
            type: type,
            horizontal: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2),
            vertical: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
            fixedHorizontal: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
            fixedVertical: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
            scrollPhase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
            momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        )
    }

    private func shouldBlockTrackpadSwipe(type: CGEventType, event: CGEvent) -> Bool {
        guard type == swipeGestureEventType,
              let nsEvent = NSEvent(cgEvent: event) else {
            return false
        }

        return FocusInputFilter.shouldBlockTrackpadSwipe(
            eventType: nsEvent.type,
            deltaX: nsEvent.deltaX,
            deltaY: nsEvent.deltaY
        )
    }

    private func tearDown() {
        isLocked = false
        timer?.invalidate()
        timer = nil

        if let observer = spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            spaceObserver = nil
        }

        // Tear down event tap: remove from run loop first, then invalidate
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }

        if let monitor = localSwipeMonitor {
            NSEvent.removeMonitor(monitor)
            localSwipeMonitor = nil
        }
        if let monitor = globalSwipeMonitor {
            NSEvent.removeMonitor(monitor)
            globalSwipeMonitor = nil
        }

        systemGestureSettings.restoreHorizontalSpaceSwipes()

        // Hide instead of close — isReleasedWhenClosed=false means ARC handles release
        anchorWindow?.orderOut(nil)
        anchorWindow = nil
    }

    // Visible "LOCKED" badge in the corner — this is what we snap back to
    private func setupAnchorWindow() {
        guard let screen = NSScreen.main else { return }
        let r = screen.visibleFrame
        let w: CGFloat = 140, h: CGFloat = 36
        let origin = NSPoint(x: r.maxX - w - 16, y: r.maxY - h - 8)

        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: NSSize(width: w, height: h)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        // Disable the window-appear animation — avoids _NSWindowTransformAnimation crash on macOS 26
        window.animationBehavior = .none
        // Let ARC own the window — close() would double-release otherwise
        window.isReleasedWhenClosed = false
        // .managed keeps it on one space; activating it will switch back to that space
        window.collectionBehavior = [.managed]
        // Don't steal mouse events from the user's work
        window.ignoresMouseEvents = true

        // Plain custom-drawn view — no wantsLayer, no subviews, avoids CA animation bug
        window.contentView = LockedBadgeView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        window.orderFront(nil)
        self.anchorWindow = window
    }

    private func setupSpaceObserver() {
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.snapBack()
        }
    }

    private func snapBack() {
        guard isLocked, let window = anchorWindow else { return }
        // Retry across a short window to handle transition animations
        for delay in [0.0, 0.1, 0.25, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak window] in
                guard self?.isLocked == true, let window else { return }
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func setupSwipeMonitors() {
        localSwipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .swipe) { [weak self] event in
            guard self?.isLocked == true,
                  FocusInputFilter.shouldBlockTrackpadSwipe(
                    eventType: event.type,
                    deltaX: event.deltaX,
                    deltaY: event.deltaY
                  ) else {
                return event
            }
            return nil
        }

        // Global monitors cannot cancel events, but this can pull focus back sooner on
        // systems that expose Space swipes to AppKit before activeSpaceDidChange fires.
        globalSwipeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .swipe) { [weak self] event in
            guard self?.isLocked == true,
                  FocusInputFilter.shouldBlockTrackpadSwipe(
                    eventType: event.type,
                    deltaX: event.deltaX,
                    deltaY: event.deltaY
                  ) else {
                return
            }
            self?.snapBack()
        }
    }

    private func setupEventTap() {
        let mask = eventMask(.keyDown)
            | eventMask(systemDefinedEventType)
            | eventMask(.scrollWheel)
            | eventMask(swipeGestureEventType)
        // passUnretained is safe — LockManager lives for the entire app lifetime
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,       // .defaultTap = active tap, can block events
            eventsOfInterest: mask,
            callback: tapCallback,
            userInfo: selfPtr
        ) else {
            print("[DesktopFocus] CGEventTap failed — grant Accessibility permission and relaunch")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        guard let end = lockEndDate else { return }
        timeRemaining = max(0, end.timeIntervalSinceNow)

        if let penaltyEnd = penaltyEndDate {
            let p = max(0, penaltyEnd.timeIntervalSinceNow)
            penaltyCooldown = p
            if p <= 0 { penaltyEndDate = nil }
        }
    }
}

// MARK: - Badge view

// Custom-drawn, no layer-backed subviews — avoids _NSWindowTransformAnimation crash
private final class LockedBadgeView: NSView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let badge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.17, alpha: 0.88).setFill()
        badge.fill()
        NSColor(calibratedRed: 0.82, green: 0.58, blue: 0.29, alpha: 0.88).setStroke()
        badge.lineWidth = 1
        badge.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(calibratedRed: 0.95, green: 0.78, blue: 0.50, alpha: 1),
            .font: NSFont.boldSystemFont(ofSize: 13)
        ]
        let text = "FOCUS LOCKED" as NSString
        let sz = text.size(withAttributes: attrs)
        text.draw(
            at: NSPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2),
            withAttributes: attrs
        )
    }
}
