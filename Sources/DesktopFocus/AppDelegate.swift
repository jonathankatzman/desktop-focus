import AppKit
import SwiftUI
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panel: StatusPanel?
    private var panelEventMonitor: Any?
    private var lockManager = LockManager()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "DesktopFocus", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.action = #selector(togglePopover)
            button.target = self
            button.imagePosition = .imageOnly
        }
        updateStatusIcon(isLocked: false)

        lockManager.$isLocked
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLocked in
                self?.updateStatusIcon(isLocked: isLocked)
                self?.repositionPanelIfNeeded()
            }
            .store(in: &cancellables)

        checkAccessibilityPermission()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard lockManager.isLocked else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Desktop Focus is locked"
        alert.informativeText = "The app is currently locked. Quitting will disable the desktop lock. Are you sure?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Anyway")

        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            lockManager.forceUnlock()
            return .terminateNow
        }
        return .terminateCancel
    }

    private func updateStatusIcon(isLocked: Bool) {
        guard let button = statusItem?.button else { return }
        button.image = StatusBarIcon.make(isLocked: isLocked)
        button.contentTintColor = nil
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if panel?.isVisible == true {
            closePanel()
        } else {
            showPanel(anchoredTo: button)
        }
    }

    private func closePanel() {
        panel?.orderOut(nil)
        if let monitor = panelEventMonitor {
            NSEvent.removeMonitor(monitor)
            panelEventMonitor = nil
        }
    }

    private func showPanel(anchoredTo button: NSStatusBarButton) {
        let panel = makePanelIfNeeded()
        position(panel: panel, anchoredTo: button)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if panelEventMonitor == nil {
            panelEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.closePanel()
            }
        }
    }

    private func repositionPanelIfNeeded() {
        guard let panel, panel.isVisible, let button = statusItem?.button else { return }
        position(panel: panel, anchoredTo: button)
    }

    private func makePanelIfNeeded() -> StatusPanel {
        if let panel { return panel }

        let panel = StatusPanel(
            contentRect: NSRect(x: 0, y: 0, width: 332, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: PanelSurface(lockManager: lockManager))
        self.panel = panel
        return panel
    }

    private func position(panel: NSPanel, anchoredTo button: NSStatusBarButton) {
        guard let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else {
            return
        }

        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonRectOnScreen = buttonWindow.convertToScreen(buttonRectInWindow)
        let width: CGFloat = 332
        let height: CGFloat = lockManager.isLocked ? 420 : 296
        let margin: CGFloat = 8
        let gap: CGFloat = 6

        let maxX = screen.visibleFrame.maxX - margin
        let minX = screen.visibleFrame.minX + margin
        let x = min(max(buttonRectOnScreen.midX - width / 2, minX), maxX - width)
        let topY = min(buttonRectOnScreen.minY - gap, screen.visibleFrame.maxY - gap)
        let y = max(screen.visibleFrame.minY + margin, topY - height)

        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    private func checkAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if !trusted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let alert = NSAlert()
                alert.messageText = "Accessibility Permission Required"
                alert.informativeText = "Desktop Focus needs Accessibility access to intercept shortcuts and gestures that switch desktops. Please grant access in System Settings > Privacy & Security > Accessibility, then relaunch the app."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
        }
    }
}

private final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct PanelSurface: View {
    @ObservedObject var lockManager: LockManager

    var body: some View {
        MenuBarView(lockManager: lockManager)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            )
    }
}

private enum StatusBarIcon {
    static func make(isLocked: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let accent = NSColor(calibratedRed: 0.82, green: 0.58, blue: 0.29, alpha: 1)
            let teal = NSColor(calibratedRed: 0.21, green: 0.67, blue: 0.69, alpha: 1)
            let line = isLocked ? accent : NSColor.labelColor.withAlphaComponent(0.86)
            let secondary = isLocked ? teal.withAlphaComponent(0.78) : NSColor.labelColor.withAlphaComponent(0.42)

            NSColor.clear.setFill()
            rect.fill()

            let desktop = NSBezierPath(roundedRect: NSRect(x: 2.2, y: 3.1, width: 13.6, height: 11.8), xRadius: 3, yRadius: 3)
            (isLocked ? accent.withAlphaComponent(0.13) : NSColor.clear).setFill()
            desktop.fill()
            line.setStroke()
            desktop.lineWidth = 1.4
            desktop.stroke()

            let focusRing = NSBezierPath(ovalIn: NSRect(x: 5.2, y: 5.4, width: 7.6, height: 7.6))
            secondary.setStroke()
            focusRing.lineWidth = 1.15
            focusRing.stroke()

            if isLocked {
                let shackle = NSBezierPath()
                shackle.move(to: NSPoint(x: 7.0, y: 9.1))
                shackle.curve(
                    to: NSPoint(x: 11.0, y: 9.1),
                    controlPoint1: NSPoint(x: 7.0, y: 12.1),
                    controlPoint2: NSPoint(x: 11.0, y: 12.1)
                )
                line.setStroke()
                shackle.lineWidth = 1.55
                shackle.stroke()

                let body = NSBezierPath(roundedRect: NSRect(x: 6.0, y: 4.7, width: 6.0, height: 5.6), xRadius: 1.4, yRadius: 1.4)
                line.setFill()
                body.fill()

                NSColor.black.withAlphaComponent(0.42).setFill()
                NSBezierPath(ovalIn: NSRect(x: 8.35, y: 6.25, width: 1.3, height: 1.3)).fill()
                NSBezierPath(roundedRect: NSRect(x: 8.72, y: 5.25, width: 0.55, height: 1.5), xRadius: 0.25, yRadius: 0.25).fill()
            } else {
                let body = NSBezierPath(roundedRect: NSRect(x: 6.0, y: 4.7, width: 6.0, height: 5.6), xRadius: 1.4, yRadius: 1.4)
                line.setStroke()
                body.lineWidth = 1.25
                body.stroke()

                let shackle = NSBezierPath()
                shackle.move(to: NSPoint(x: 7.3, y: 9.2))
                shackle.curve(
                    to: NSPoint(x: 12.1, y: 10.3),
                    controlPoint1: NSPoint(x: 7.1, y: 12.0),
                    controlPoint2: NSPoint(x: 10.8, y: 12.6)
                )
                line.setStroke()
                shackle.lineWidth = 1.4
                shackle.stroke()
            }

            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = isLocked ? "Desktop Focus locked" : "Desktop Focus unlocked"
        return image
    }
}
