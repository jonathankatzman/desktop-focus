import XCTest
@testable import DesktopFocus

final class SpaceRecoveryTests: XCTestCase {
    func testCoalescesRequestsAndStopsOnTheTargetSpace() {
        let recovery = SpaceRecovery(retryInterval: 0.01)
        defer { recovery.cancel() }
        let returned = expectation(description: "Returned to target Space")
        let extraAttempt = expectation(description: "Attempted activation after returning")
        extraAttempt.isInverted = true
        var onTarget = false
        var attempts = 0
        let activate = {
            attempts += 1
            if attempts == 2 {
                onTarget = true
                returned.fulfill()
            } else if attempts > 2 {
                extraAttempt.fulfill()
            }
        }

        recovery.recoverIfNeeded(isOnTargetSpace: { onTarget }, returnToTargetSpace: activate)
        recovery.recoverIfNeeded(isOnTargetSpace: { onTarget }, returnToTargetSpace: activate)

        XCTAssertEqual(attempts, 1)
        wait(for: [returned, extraAttempt], timeout: 0.25)
        XCTAssertEqual(attempts, 2)
    }

    func testCancellationStopsPendingRetries() {
        let recovery = SpaceRecovery(retryInterval: 0.01)
        defer { recovery.cancel() }
        let retry = expectation(description: "Retried after cancellation")
        retry.isInverted = true
        var attempts = 0

        recovery.recoverIfNeeded(isOnTargetSpace: { false }) {
            attempts += 1
            if attempts > 1 { retry.fulfill() }
        }
        recovery.cancel()

        wait(for: [retry], timeout: 0.1)
        XCTAssertEqual(attempts, 1)
    }

    func testStopsAfterFourFailedAttempts() {
        let recovery = SpaceRecovery(retryInterval: 0.01)
        defer { recovery.cancel() }
        let lastAttempt = expectation(description: "Reached fourth activation attempt")
        let extraAttempt = expectation(description: "Retried after reaching the attempt limit")
        extraAttempt.isInverted = true
        var attempts = 0

        recovery.recoverIfNeeded(isOnTargetSpace: { false }) {
            attempts += 1
            if attempts == 4 {
                lastAttempt.fulfill()
            } else if attempts > 4 {
                extraAttempt.fulfill()
            }
        }

        wait(for: [lastAttempt, extraAttempt], timeout: 0.25)
        XCTAssertEqual(attempts, 4)
    }
}
