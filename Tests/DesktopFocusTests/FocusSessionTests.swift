import Foundation
import XCTest
@testable import DesktopFocus

final class FocusSessionTests: XCTestCase {
    private let start = ContinuousClock.now

    func testCountdownEndsAtDeadlineEvenDuringCooldown() {
        var session = FocusSession(duration: 10, startedAt: start, unlockCode: "0123")

        for _ in 0..<3 {
            XCTAssertEqual(session.attemptUnlock(code: "9999", at: start), .incorrect)
        }

        XCTAssertEqual(session.remaining(at: start.advanced(by: .seconds(9))), 1)
        let deadline = start.advanced(by: .seconds(10))
        XCTAssertEqual(session.remaining(at: deadline), 0)
        XCTAssertEqual(session.remaining(at: deadline.advanced(by: .seconds(1))), 0)
        XCTAssertGreaterThan(session.cooldownRemaining(at: deadline), 0)
        XCTAssertEqual(session.attemptUnlock(code: "0123", at: deadline), .ignored)
    }

    func testInvalidInputDoesNotCountTowardCooldown() {
        var session = FocusSession(duration: 120, startedAt: start, unlockCode: "0123")

        for code in ["", "0", "012", "01234", "٠١٢٣"] {
            XCTAssertEqual(session.attemptUnlock(code: code, at: start), .ignored)
        }
        XCTAssertEqual(session.cooldownRemaining(at: start), 0)
        XCTAssertEqual(session.attemptUnlock(code: "0123", at: start), .unlocked)
    }

    func testCorrectCodeIsAcceptedAsSoonAsCooldownEnds() {
        var session = FocusSession(duration: 120, startedAt: start, unlockCode: "0123")

        for _ in 0..<3 {
            XCTAssertEqual(session.attemptUnlock(code: "9999", at: start), .incorrect)
        }

        let beforeCooldownEnds = start.advanced(by: .milliseconds(59_750))
        XCTAssertEqual(session.cooldownRemaining(at: beforeCooldownEnds), 0.25)
        XCTAssertEqual(session.attemptUnlock(code: "0123", at: beforeCooldownEnds), .ignored)
        XCTAssertEqual(session.attemptUnlock(code: "0123", at: start.advanced(by: .seconds(60))), .unlocked)
    }

    func testNormalizationPreservesLeadingZeroAndKeepsOnlyFourASCIIDigits() {
        XCTAssertEqual(FocusSession.normalizedCode(" 0-1٢23 4"), "0123")
    }
}
