import Foundation

final class SystemGestureSettings {
    private struct PreferenceKey {
        let domain: String
        let name: String
    }

    private struct SavedPreference {
        let key: PreferenceKey
        let value: Int?
    }

    private static let backupKey = "DesktopFocusSavedHorizontalSwipePreferences"

    private let keys = [
        PreferenceKey(
            domain: "com.apple.AppleMultitouchTrackpad",
            name: "TrackpadThreeFingerHorizSwipeGesture"
        ),
        PreferenceKey(
            domain: "com.apple.driver.AppleBluetoothMultitouch.trackpad",
            name: "TrackpadThreeFingerHorizSwipeGesture"
        ),
        PreferenceKey(
            domain: "com.apple.AppleMultitouchTrackpad",
            name: "TrackpadFourFingerHorizSwipeGesture"
        ),
        PreferenceKey(
            domain: "com.apple.driver.AppleBluetoothMultitouch.trackpad",
            name: "TrackpadFourFingerHorizSwipeGesture"
        ),
    ]

    private var savedPreferences: [SavedPreference]?

    init() {
        restoreBackedUpPreferencesIfNeeded()
    }

    func suspendHorizontalSpaceSwipes() {
        guard savedPreferences == nil else { return }

        let saved = keys.map { key in
            SavedPreference(key: key, value: readInteger(for: key))
        }
        savedPreferences = saved
        writeBackup(saved)

        for key in keys {
            write(0, for: key)
        }
        synchronize()
    }

    func restoreHorizontalSpaceSwipes() {
        guard let savedPreferences else { return }
        restore(savedPreferences)
        self.savedPreferences = nil
        UserDefaults.standard.removeObject(forKey: Self.backupKey)
    }

    private func restoreBackedUpPreferencesIfNeeded() {
        let saved = readBackup()
        guard !saved.isEmpty else { return }
        restore(saved)
        UserDefaults.standard.removeObject(forKey: Self.backupKey)
    }

    private func restore(_ saved: [SavedPreference]) {
        for preference in saved {
            if let value = preference.value {
                write(value, for: preference.key)
            } else {
                remove(preference.key)
            }
        }
        synchronize()
    }

    private func readInteger(for key: PreferenceKey) -> Int? {
        UserDefaults(suiteName: key.domain)?.object(forKey: key.name) as? Int
    }

    private func write(_ value: Int, for key: PreferenceKey) {
        let defaults = UserDefaults(suiteName: key.domain)
        defaults?.set(value, forKey: key.name)
        defaults?.synchronize()
    }

    private func remove(_ key: PreferenceKey) {
        let defaults = UserDefaults(suiteName: key.domain)
        defaults?.removeObject(forKey: key.name)
        defaults?.synchronize()
    }

    private func synchronize() {
        for domain in Set(keys.map(\.domain)) {
            UserDefaults(suiteName: domain)?.synchronize()
            CFPreferencesAppSynchronize(domain as CFString)
        }

        DistributedNotificationCenter.default().post(
            name: Notification.Name("com.apple.MultitouchSupport.preferencesChanged"),
            object: nil
        )
    }

    private func writeBackup(_ saved: [SavedPreference]) {
        let backup = saved.map { preference in
            [
                "domain": preference.key.domain,
                "name": preference.key.name,
                "hasValue": preference.value != nil,
                "value": preference.value ?? 0,
            ] as [String: Any]
        }
        UserDefaults.standard.set(backup, forKey: Self.backupKey)
    }

    private func readBackup() -> [SavedPreference] {
        guard let backup = UserDefaults.standard.array(forKey: Self.backupKey) as? [[String: Any]] else {
            return []
        }

        return backup.compactMap { item in
            guard let domain = item["domain"] as? String,
                  let name = item["name"] as? String,
                  let hasValue = item["hasValue"] as? Bool else {
                return nil
            }

            let value = hasValue ? item["value"] as? Int : nil
            return SavedPreference(key: PreferenceKey(domain: domain, name: name), value: value)
        }
    }
}
