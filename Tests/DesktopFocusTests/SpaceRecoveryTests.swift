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
            } else if attempts > 2 {
                extraAttempt.fulfill()
            }
        }
        let didFinish: (Bool) -> Void = { onTarget in
            XCTAssertTrue(onTarget)
            returned.fulfill()
        }

        recovery.recoverIfNeeded(isOnTargetSpace: { onTarget }, returnToTargetSpace: activate, didFinish: didFinish)
        recovery.recoverIfNeeded(isOnTargetSpace: { onTarget }, returnToTargetSpace: activate, didFinish: didFinish)

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

        recovery.recoverIfNeeded(isOnTargetSpace: { false }, returnToTargetSpace: {
            attempts += 1
            if attempts > 1 { retry.fulfill() }
        }, didFinish: { _ in XCTFail("Cancelled recovery reported a result") })
        recovery.cancel()

        wait(for: [retry], timeout: 0.1)
        XCTAssertEqual(attempts, 1)
    }

    func testReportsFailureAfterFourAttemptsAndClearsWhenBackOnTarget() {
        let recovery = SpaceRecovery(retryInterval: 0.01)
        defer { recovery.cancel() }
        let failed = expectation(description: "Reported failed recovery")
        let extraAttempt = expectation(description: "Retried after reaching the attempt limit")
        extraAttempt.isInverted = true
        var attempts = 0

        recovery.recoverIfNeeded(isOnTargetSpace: { false }, returnToTargetSpace: {
            attempts += 1
            if attempts > 4 { extraAttempt.fulfill() }
        }, didFinish: { onTarget in
            XCTAssertFalse(onTarget)
            XCTAssertEqual(attempts, 4)
            failed.fulfill()
        })

        wait(for: [failed, extraAttempt], timeout: 0.25)
        XCTAssertEqual(attempts, 4)

        let returned = expectation(description: "Recognized the manual return")
        recovery.recoverIfNeeded(isOnTargetSpace: { true }, returnToTargetSpace: {
            XCTFail("Activated the app while already on the target Space")
        }, didFinish: { onTarget in
            XCTAssertTrue(onTarget)
            returned.fulfill()
        })
        wait(for: [returned], timeout: 0.25)
    }

    func testChecksTargetAgainAfterLastActivation() {
        let recovery = SpaceRecovery(retryInterval: 0.01)
        defer { recovery.cancel() }
        let returned = expectation(description: "Recognized that the fourth activation succeeded")
        var attempts = 0

        recovery.recoverIfNeeded(isOnTargetSpace: { attempts == 4 }, returnToTargetSpace: {
            attempts += 1
        }, didFinish: { onTarget in
            XCTAssertTrue(onTarget)
            returned.fulfill()
        })

        wait(for: [returned], timeout: 0.25)
        XCTAssertEqual(attempts, 4)
    }
}
