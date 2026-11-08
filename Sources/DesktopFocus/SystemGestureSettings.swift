import Darwin
import Foundation

struct GesturePreferenceKey: Codable, Hashable {
    let domain: String
    let name: String
    var currentHost = false
}

protocol GesturePreferenceStore {
    func read(_ key: GesturePreferenceKey) throws -> Int?
    func write(_ value: Int?, for key: GesturePreferenceKey)
    func synchronize(_ key: GesturePreferenceKey) -> Bool
}

private struct UserGesturePreferences: GesturePreferenceStore {
    private func domain(_ key: GesturePreferenceKey) -> CFString {
        key.domain == ".GlobalPreferences" ? kCFPreferencesAnyApplication : key.domain as CFString
    }

    private func host(_ key: GesturePreferenceKey) -> CFString {
        key.currentHost ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost
    }

    func read(_ key: GesturePreferenceKey) throws -> Int? {
        let value = CFPreferencesCopyValue(key.name as CFString, domain(key), kCFPreferencesCurrentUser, host(key))
        guard let value else { return nil }
        guard let number = value as? NSNumber,
              number.doubleValue == Double(number.intValue) else { throw GestureSettingsError.couldNotApply }
        return number.intValue
    }

    func write(_ value: Int?, for key: GesturePreferenceKey) {
        CFPreferencesSetValue(key.name as CFString, value.map(NSNumber.init(value:)), domain(key),
                              kCFPreferencesCurrentUser, host(key))
    }

    func synchronize(_ key: GesturePreferenceKey) -> Bool {
        CFPreferencesSynchronize(domain(key), kCFPreferencesCurrentUser, host(key))
    }
}

enum GestureSettingsError: Error {
    case anotherSessionActive
    case couldNotApply
    case couldNotRestore
}

final class SystemGestureSettings {
    private struct SavedPreference: Codable {
        let key: GesturePreferenceKey
        let value: Int?
    }

    static let keys: [GesturePreferenceKey] = [
        "com.apple.AppleMultitouchTrackpad",
        "com.apple.driver.AppleBluetoothMultitouch.trackpad"
    ].flatMap { domain in
        ["TrackpadThreeFingerHorizSwipeGesture", "TrackpadFourFingerHorizSwipeGesture"].map {
            GesturePreferenceKey(domain: domain, name: $0)
        }
    } + ["threeFingerHorizSwipeGesture", "fourFingerHorizSwipeGesture"].map {
        GesturePreferenceKey(domain: ".GlobalPreferences", name: "com.apple.trackpad.\($0)", currentHost: true)
    } + ["com.apple.AppleMultitouchMouse", "com.apple.driver.AppleBluetoothMultitouch.mouse"].map {
        GesturePreferenceKey(domain: $0, name: "MouseTwoFingerHorizSwipeGesture")
    }

    private let preferences: GesturePreferenceStore
    private let journalURL: URL
    private let activate: () -> Bool
    private var lockFile: Int32 = -1

    convenience init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DesktopFocus", isDirectory: true)
        self.init(preferences: UserGesturePreferences(),
                  journalURL: directory.appendingPathComponent("gesture-settings.json"),
                  activate: Self.activateSettings)
    }

    init(preferences: GesturePreferenceStore, journalURL: URL, activate: @escaping () -> Bool) {
        self.preferences = preferences
        self.journalURL = journalURL
        self.activate = activate
    }

    deinit {
        releaseLock()
    }

    func suspendHorizontalSpaceSwipes() throws {
        try acquireLock()
        do {
            try restoreJournal()
            let saved = try Self.keys.compactMap { key -> SavedPreference? in
                let value = try preferences.read(key)
                // 1 is page navigation. Preserve it. An absent value may use the
                // driver's Space-swipe default, so override it and remove it later.
                guard value == nil || value == 2 else { return nil }
                return SavedPreference(key: key, value: value)
            }
            guard !saved.isEmpty else { return }
            try JSONEncoder().encode(saved).write(to: journalURL, options: .atomic)
            for item in saved {
                preferences.write(0, for: item.key)
                guard preferences.synchronize(item.key) else { throw GestureSettingsError.couldNotApply }
                guard try preferences.read(item.key) == 0 else { throw GestureSettingsError.couldNotApply }
            }
            guard activate() else { throw GestureSettingsError.couldNotApply }
        } catch {
            do {
                try restoreJournal()
            } catch {
                releaseLock()
                throw GestureSettingsError.couldNotRestore
            }
            releaseLock()
            throw error
        }
    }

    func restoreHorizontalSpaceSwipes() throws {
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            releaseLock()
            return
        }
        try acquireLock()
        defer { releaseLock() }
        try restoreJournal()
    }

    private func restoreJournal() throws {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
        let saved = try JSONDecoder().decode([SavedPreference].self, from: Data(contentsOf: journalURL))
        for item in saved {
            // Preserve a setting the user changed themselves during the session.
            let current = try preferences.read(item.key)
            let expected = current == 0 ? item.value : current
            if current == 0 {
                preferences.write(item.value, for: item.key)
            }
            guard preferences.synchronize(item.key) else { throw GestureSettingsError.couldNotRestore }
            guard try preferences.read(item.key) == expected else { throw GestureSettingsError.couldNotRestore }
        }
        // A previous restore may have written values but failed to reload them.
        guard activate() else { throw GestureSettingsError.couldNotRestore }
        try FileManager.default.removeItem(at: journalURL)
    }

    private func acquireLock() throws {
        guard lockFile == -1 else { return }
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let descriptor = open(journalURL.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw GestureSettingsError.couldNotApply }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw GestureSettingsError.anotherSessionActive
        }
        lockFile = descriptor
    }

    private func releaseLock() {
        guard lockFile >= 0 else { return }
        flock(lockFile, LOCK_UN)
        close(lockFile)
        lockFile = -1
    }

    private static func activateSettings() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath:
            "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings")
        process.arguments = ["-u"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return false
        }
        if finished.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            return false
        }
        return process.terminationStatus == 0
    }
}
