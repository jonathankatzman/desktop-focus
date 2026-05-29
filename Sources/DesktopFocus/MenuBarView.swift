import SwiftUI

private let focusAmber = Color(red: 0.78, green: 0.52, blue: 0.25)
private let focusTeal = Color(red: 0.18, green: 0.58, blue: 0.60)

private let durations: [(label: String, seconds: TimeInterval)] = [
    ("25 min", 25 * 60),
    ("45 min", 45 * 60),
    ("1 hour", 60 * 60),
    ("90 min", 90 * 60),
    ("2 hours", 2 * 60 * 60),
    ("4 hours", 4 * 60 * 60),
]

struct MenuBarView: View {
    @ObservedObject var lockManager: LockManager
    @State private var selectedDuration: TimeInterval = 25 * 60
    @State private var unlockAttempt = ""
    @State private var showWrongCode = false

    var body: some View {
        Group {
            if lockManager.isLocked {
                LockedView(
                    lockManager: lockManager,
                    unlockAttempt: $unlockAttempt,
                    showWrongCode: $showWrongCode,
                    onAttempt: attemptUnlock
                )
            } else {
                UnlockedView(
                    selectedDuration: $selectedDuration,
                    onLock: { lockManager.lock(duration: selectedDuration) }
                )
            }
        }
        .frame(width: 300)
        .padding(16)
    }

    private func attemptUnlock() {
        let success = lockManager.attemptUnlock(code: unlockAttempt)
        if success {
            unlockAttempt = ""
            showWrongCode = false
        } else {
            showWrongCode = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                unlockAttempt = ""
            }
        }
    }
}

// MARK: - Unlocked

struct UnlockedView: View {
    @Binding var selectedDuration: TimeInterval
    let onLock: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "lock.open.fill").foregroundColor(.secondary)
                Text("Desktop Focus").font(.headline)
            }

            Text("Lock yourself to the current desktop. Space-switch shortcuts and gestures will be blocked.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("Duration").font(.subheadline.weight(.semibold))

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                spacing: 8
            ) {
                ForEach(durations, id: \.seconds) { item in
                    Button(item.label) { selectedDuration = item.seconds }
                        .buttonStyle(DurationButtonStyle(isSelected: selectedDuration == item.seconds))
                }
            }

            Button(action: onLock) {
                Label("Lock to This Desktop", systemImage: "scope")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(focusTeal)
            .padding(.top, 4)

            Divider()

            Button("Quit") { NSApp.terminate(nil) }
                .foregroundColor(.secondary).font(.caption)
        }
    }
}

struct DurationButtonStyle: ButtonStyle {
    let isSelected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(isSelected ? .semibold : .regular))
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.15))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(6)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

// MARK: - Locked

struct LockedView: View {
    @ObservedObject var lockManager: LockManager
    @Binding var unlockAttempt: String
    @Binding var showWrongCode: Bool
    let onAttempt: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Image(systemName: "lock.shield.fill").foregroundColor(focusAmber)
                Text("Desktop Locked").font(.headline).foregroundColor(.primary)
            }

            Divider()

            // Timer — informational only, does not gate the code
            VStack(spacing: 4) {
                Text(formatTime(lockManager.timeRemaining))
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                    .foregroundColor(lockManager.timeRemaining > 0 ? .primary : .green)
                Text(lockManager.timeRemaining > 0 ? "remaining" : "time's up")
                    .font(.caption).foregroundColor(.secondary)
            }

            Divider()

            // Unlock code — always visible, always enterable
            VStack(spacing: 10) {
                Text("Escape Hatch Code")
                    .font(.caption.weight(.semibold)).foregroundColor(.secondary)

                Text(lockManager.unlockCode)
                    .font(.system(size: 34, weight: .heavy, design: .monospaced))
                    .foregroundColor(focusAmber)
                    .padding(.horizontal, 24).padding(.vertical, 10)
                    .background(focusAmber.opacity(0.12))
                    .cornerRadius(10)

                if lockManager.penaltyCooldown > 0 {
                    VStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(focusAmber)
                        Text("3 wrong attempts — wait \(Int(lockManager.penaltyCooldown))s")
                            .font(.caption).foregroundColor(focusAmber)
                    }
                } else {
                    VStack(spacing: 6) {
                        TextField("Type code to unlock", text: $unlockAttempt)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.center)
                            .font(.system(size: 22, weight: .bold, design: .monospaced))
                            .onChange(of: unlockAttempt) { newValue in
                                let digits = newValue.filter { $0.isNumber }
                                if digits != newValue { unlockAttempt = digits }
                                if unlockAttempt.count > 4 { unlockAttempt = String(unlockAttempt.prefix(4)) }
                                if unlockAttempt.count == 4 { onAttempt() }
                            }
                            .onSubmit { onAttempt() }

                        if showWrongCode {
                            Text("Wrong code — try again.")
                                .font(.caption).foregroundColor(.red)
                        } else {
                            Text("Works at any time, even mid-session.")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let h = Int(interval) / 3600
        let m = (Int(interval) % 3600) / 60
        let s = Int(interval) % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
