import Foundation
import XCTest
@testable import DesktopFocus

final class SystemGestureSettingsTests: XCTestCase {
    private var directory: URL!
    private var journal: URL { directory.appendingPathComponent("settings.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testRestoresConfiguredValuesAndRemovesTemporaryDefaults() throws {
        let keys = SystemGestureSettings.keys
        let store = TestGesturePreferences(values: [keys[0]: 2, keys[1]: 1, keys[2]: 0])
        let original = store.values
        let settings = SystemGestureSettings(preferences: store, journalURL: journal, activate: { true })

        try settings.suspendHorizontalSpaceSwipes()
        XCTAssertEqual(store.values[keys[0]], 0)
        XCTAssertEqual(store.values[keys[1]], 1)
        XCTAssertEqual(store.values[keys[2]], 0)
        XCTAssertEqual(store.values[keys[4]], 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))

        try settings.restoreHorizontalSpaceSwipes()
        XCTAssertEqual(store.values, original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }

    func testDriverReloadFailureRollsBackChanges() {
        let key = SystemGestureSettings.keys[0]
        let store = TestGesturePreferences(values: [key: 2])
        let original = store.values
        var reloads = 0
        let settings = SystemGestureSettings(preferences: store, journalURL: journal) {
            reloads += 1
            return reloads > 1
        }

        XCTAssertThrowsError(try settings.suspendHorizontalSpaceSwipes())
        XCTAssertEqual(store.values, original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertEqual(reloads, 2)
    }

    func testPreferenceWriteFailureRollsBackPartialChanges() {
        let key = SystemGestureSettings.keys[0]
        let store = TestGesturePreferences(values: [key: 2])
        let original = store.values
        store.failNextSynchronization = true
        let settings = SystemGestureSettings(preferences: store, journalURL: journal, activate: { true })

        XCTAssertThrowsError(try settings.suspendHorizontalSpaceSwipes())
        XCTAssertEqual(store.values, original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }

    func testIgnoredPreferenceWriteDoesNotStartAGuard() {
        let key = SystemGestureSettings.keys[0]
        let store = TestGesturePreferences(values: [key: 2])
        store.ignoreWrites = true
        let settings = SystemGestureSettings(preferences: store, journalURL: journal, activate: { true })

        XCTAssertThrowsError(try settings.suspendHorizontalSpaceSwipes())
        XCTAssertEqual(store.values, [key: 2])
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }

    func testRelaunchRecoversJournalAndPreservesUserChanges() throws {
        let keys = SystemGestureSettings.keys
        let store = TestGesturePreferences(values: [keys[0]: 2, keys[1]: 2])
        var settings: SystemGestureSettings? = SystemGestureSettings(
            preferences: store, journalURL: journal, activate: { true })
        try settings?.suspendHorizontalSpaceSwipes()
        // Simulate an unclean process exit. The journal survives and the lock is released.
        settings = nil
        store.values[keys[1]] = 1

        let relaunched = SystemGestureSettings(preferences: store, journalURL: journal, activate: { true })
        try relaunched.restoreHorizontalSpaceSwipes()

        XCTAssertEqual(store.values, [keys[0]: 2, keys[1]: 1])
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }

    func testFailedRestorationKeepsJournalForRetry() throws {
        let key = SystemGestureSettings.keys[0]
        let store = TestGesturePreferences(values: [key: 2])
        var reloadSucceeds = true
        let settings = SystemGestureSettings(preferences: store, journalURL: journal) { reloadSucceeds }
        try settings.suspendHorizontalSpaceSwipes()

        reloadSucceeds = false
        XCTAssertThrowsError(try settings.restoreHorizontalSpaceSwipes())
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))

        reloadSucceeds = true
        try settings.restoreHorizontalSpaceSwipes()
        XCTAssertEqual(store.values, [key: 2])
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }

    func testIgnoredRestoreWriteKeepsSnapshotForRetry() throws {
        let key = SystemGestureSettings.keys[0]
        let store = TestGesturePreferences(values: [key: 2])
        let original = store.values
        let settings = SystemGestureSettings(preferences: store, journalURL: journal, activate: { true })
        try settings.suspendHorizontalSpaceSwipes()

        store.ignoreWrites = true
        XCTAssertThrowsError(try settings.restoreHorizontalSpaceSwipes())
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))

        store.ignoreWrites = false
        try settings.restoreHorizontalSpaceSwipes()
        XCTAssertEqual(store.values, original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }

    func testPartialRestoreCanBeRetriedAfterSynchronizationFailure() throws {
        let key = SystemGestureSettings.keys[0]
        let store = TestGesturePreferences(values: [key: 2])
        let original = store.values
        let settings = SystemGestureSettings(preferences: store, journalURL: journal, activate: { true })
        try settings.suspendHorizontalSpaceSwipes()

        store.failNextSynchronization = true
        XCTAssertThrowsError(try settings.restoreHorizontalSpaceSwipes())
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))

        try settings.restoreHorizontalSpaceSwipes()
        XCTAssertEqual(store.values, original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }

    func testConcurrentInstanceCannotOverwriteActiveSnapshot() throws {
        let key = SystemGestureSettings.keys[0]
        let store = TestGesturePreferences(values: [key: 2])
        let first = SystemGestureSettings(preferences: store, journalURL: journal, activate: { true })
        try first.suspendHorizontalSpaceSwipes()
        defer { try? first.restoreHorizontalSpaceSwipes() }
        let savedJournal = try Data(contentsOf: journal)

        let second = SystemGestureSettings(preferences: store, journalURL: journal, activate: { true })
        XCTAssertThrowsError(try second.suspendHorizontalSpaceSwipes())
        XCTAssertEqual(try Data(contentsOf: journal), savedJournal)
        XCTAssertEqual(store.values[key], 0)
    }
}

final class TestGesturePreferences: GesturePreferenceStore {
    var values: [GesturePreferenceKey: Int]
    var failNextSynchronization = false
    var ignoreWrites = false

    init(values: [GesturePreferenceKey: Int]) {
        self.values = values
    }

    func read(_ key: GesturePreferenceKey) -> Int? { values[key] }
    func write(_ value: Int?, for key: GesturePreferenceKey) {
        if !ignoreWrites { values[key] = value }
    }
    func synchronize(_ key: GesturePreferenceKey) -> Bool {
        if failNextSynchronization {
            failNextSynchronization = false
            return false
        }
        return true
    }
}
