import AppKit
import Combine

// Free function required for CGEventTap C callback
private func tapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<LockManager>.fromOpaque(refcon).takeUnretainedValue()
    return manager.filterEvent(type: type, event: event)
}

let systemDefinedEventType = CGEventType(rawValue: 14)!
let swipeGestureEventType = CGEventType(rawValue: UInt32(NSEvent.EventType.swipe.rawValue))!

private func eventMask(_ type: CGEventType) -> CGEventMask {
    CGEventMask(1) << type.rawValue
}

struct FocusInputFilter {
    static let tapMask = eventMask(.keyDown)
        | eventMask(systemDefinedEventType)
        | eventMask(swipeGestureEventType)

    static let auxControlButtonSubtype = 8
    static let topRowDigitKeyCodes: Set<Int> = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
    private static let shortcutModifiers: CGEventFlags = [.maskControl, .maskCommand, .maskAlternate, .maskShift]

    static func shouldBlockKeyboardShortcut(
        type: CGEventType,
        keyCode: Int,
        flags: CGEventFlags
    ) -> Bool {
        guard type == .keyDown else { return false }

        if flags.intersection(shortcutModifiers) == .maskControl {
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

    static func shouldBlockTrackpadSwipe(
        eventType: NSEvent.EventType,
        deltaX: CGFloat,
        deltaY: CGFloat
    ) -> Bool {
        guard eventType == .swipe else { return false }
        return abs(deltaX) > 0 && abs(deltaX) >= abs(deltaY)
    }
}

enum LockStartError: Equatable {
    case accessibilityRequired
    case inputUnavailable
    case desktopUnavailable

    var message: String {
        switch self {
        case .accessibilityRequired:
            return "Allow Desktop Focus in Accessibility settings, then try again."
        case .inputUnavailable:
            return "macOS couldn’t start input interception. Reopen Desktop Focus and try again."
        case .desktopUnavailable:
            return "Desktop Focus couldn’t find an active display. Try again when a display is available."
        }
    }
}

class LockManager: ObservableObject {
    @Published private(set) var isLocked = false
    @Published private(set) var timeRemaining: TimeInterval = 0
    @Published private(set) var penaltyCooldown: TimeInterval = 0
    @Published private(set) var startError: LockStartError?

    var unlockCode: String { session?.unlockCode ?? "" }

    private var session: FocusSession?
    private var anchorWindow: NSWindow?
    private var spaceObserver: Any?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var localSwipeMonitor: Any?
    private var globalSwipeMonitor: Any?
    private var timer: Timer?

    func lock(duration: TimeInterval) {
        guard !isLocked, duration.isFinite, duration > 0 else { return }
        guard AXIsProcessTrusted() else {
            startError = .accessibilityRequired
            return
        }
        guard let screen = NSScreen.main else {
            startError = .desktopUnavailable
            return
        }
        guard setupEventTap() else {
            startError = .inputUnavailable
            return
        }

        setupAnchorWindow(on: screen)
        setupSpaceObserver()
        setupSwipeMonitors()
        let code = String(format: "%04d", Int.random(in: 0...9999))
        session = FocusSession(duration: duration, startedAt: Date(), unlockCode: code)
        timeRemaining = duration
        startError = nil
        isLocked = true
        startTimer()
    }

    func attemptUnlock(code: String) -> UnlockResult {
        let now = Date()
        tick(at: now)
        guard let result = session?.attemptUnlock(code: code, at: now) else { return .ignored }
        if result == .unlocked {
            tearDown()
        } else if let session {
            penaltyCooldown = session.cooldownRemaining(at: now)
        }
        return result
    }

    func forceUnlock() {
        tearDown()
    }

    // Called from the CGEventTap C callback
    func filterEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if system disabled it (e.g. after timeout)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard isLocked else { return Unmanaged.passUnretained(event) }

        if shouldBlockKeyboardShortcut(type: type, event: event) { return nil }
        if shouldBlockMissionControlButton(type: type, event: event) { return nil }
        if shouldBlockTrackpadSwipe(type: type, event: event) { return nil }

        return Unmanaged.passUnretained(event)
    }

    private func shouldBlockKeyboardShortcut(type: CGEventType, event: CGEvent) -> Bool {
        guard type == .keyDown else { return false }
        return FocusInputFilter.shouldBlockKeyboardShortcut(
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
        session = nil
        timeRemaining = 0
        penaltyCooldown = 0
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

        // Hide instead of close — isReleasedWhenClosed=false means ARC handles release
        anchorWindow?.orderOut(nil)
        anchorWindow = nil
    }

    // Visible "LOCKED" badge in the corner — this is what we snap back to
    private func setupAnchorWindow(on screen: NSScreen) {
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

    private func setupEventTap() -> Bool {
        // passUnretained is safe — LockManager lives for the entire app lifetime
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,       // .defaultTap = active tap, can block events
            eventsOfInterest: FocusInputFilter.tapMask,
            callback: tapCallback,
            userInfo: selfPtr
        ) else {
            return false
        }

        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return true
    }

    private func startTimer() {
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick(at: Date())
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick(at now: Date) {
        guard let session else { return }
        let remaining = session.remaining(at: now)
        guard remaining > 0 else {
            tearDown()
            return
        }
        timeRemaining = remaining
        penaltyCooldown = session.cooldownRemaining(at: now)
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
