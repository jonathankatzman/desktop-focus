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
    static let requiredKeyboardMask = eventMask(.keyDown)
    static let optionalInputMask = eventMask(systemDefinedEventType) | eventMask(swipeGestureEventType)

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
    @Published private(set) var spaceRecoveryFailed = false

    var unlockCode: String { session?.unlockCode ?? "" }

    private var session: FocusSession?
    private var anchorWindow: NSWindow?
    private var spaceObserver: Any?
    private let spaceRecovery = SpaceRecovery()
    private var eventTaps: [(port: CFMachPort, source: CFRunLoopSource)] = []
    private var localSwipeMonitor: Any?
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
        guard Self.installInputTaps(using: installEventTap) else {
            startError = .inputUnavailable
            return
        }

        setupAnchorWindow(on: screen)
        setupSpaceObserver()
        setupLocalSwipeMonitor()
        let code = String(format: "%04d", Int.random(in: 0...9999))
        session = FocusSession(duration: duration, startedAt: .now, unlockCode: code)
        timeRemaining = duration
        startError = nil
        isLocked = true
        startTimer()
    }

    func attemptUnlock(code: String) -> UnlockResult {
        let now = ContinuousClock.now
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
            for tap in eventTaps where !CGEvent.tapIsEnabled(tap: tap.port) {
                CGEvent.tapEnable(tap: tap.port, enable: true)
            }
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
        spaceRecoveryFailed = false
        timer?.invalidate()
        timer = nil
        spaceRecovery.cancel()

        if let observer = spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            spaceObserver = nil
        }

        // Tear down event tap: remove from run loop first, then invalidate
        for tap in eventTaps {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), tap.source, .commonModes)
            CGEvent.tapEnable(tap: tap.port, enable: false)
            CFMachPortInvalidate(tap.port)
        }
        eventTaps.removeAll()

        if let monitor = localSwipeMonitor {
            NSEvent.removeMonitor(monitor)
            localSwipeMonitor = nil
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

        let window = FocusAnchorWindow(
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
        // Keep the recovery window associated with the original Space.
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
            self?.recoverAnchorSpace()
        }
    }

    private func recoverAnchorSpace() {
        guard isLocked, let window = anchorWindow else { return }
        spaceRecovery.recoverIfNeeded(
            isOnTargetSpace: { [weak window] in window?.isOnActiveSpace ?? true },
            returnToTargetSpace: { [weak window] in
                guard let window else { return }
                window.makeKeyAndOrderFront(nil)
                if #available(macOS 14, *) {
                    NSApp.activate()
                } else {
                    NSApp.activate(ignoringOtherApps: true)
                }
            },
            didFinish: { [weak self] returnedToTarget in
                guard let self, self.isLocked else { return }
                let failed = !returnedToTarget
                if self.spaceRecoveryFailed != failed {
                    self.spaceRecoveryFailed = failed
                }
            }
        )
    }

    private func setupLocalSwipeMonitor() {
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
    }

    static func installInputTaps(using install: (CGEventMask) -> Bool) -> Bool {
        // Core Graphics drops unavailable event types and returns nil if none remain.
        // Keep key-down in its own tap so optional inputs cannot hide a keyboard failure.
        guard install(FocusInputFilter.requiredKeyboardMask) else { return false }
        _ = install(FocusInputFilter.optionalInputMask)
        return true
    }

    private func installEventTap(mask: CGEventMask) -> Bool {
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
            return false
        }

        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        eventTaps.append((port: tap, source: source))
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return true
    }

    private func startTimer() {
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick(at: .now)
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick(at now: ContinuousClock.Instant) {
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

private final class FocusAnchorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

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
