import Foundation
import XCTest
@testable import DesktopFocus

final class FocusSessionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 100)

    func testCountdownEndsAtDeadlineEvenDuringCooldown() {
        var session = FocusSession(duration: 10, startedAt: start, unlockCode: "0123")

        for _ in 0..<3 {
            XCTAssertEqual(session.attemptUnlock(code: "9999", at: start), .incorrect)
        }

        XCTAssertEqual(session.remaining(at: start.addingTimeInterval(9)), 1)
        let deadline = start.addingTimeInterval(10)
        XCTAssertEqual(session.remaining(at: deadline), 0)
        XCTAssertEqual(session.remaining(at: deadline.addingTimeInterval(1)), 0)
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

        XCTAssertEqual(session.attemptUnlock(code: "0123", at: start.addingTimeInterval(59)), .ignored)
        XCTAssertEqual(session.attemptUnlock(code: "0123", at: start.addingTimeInterval(60)), .unlocked)
    }

    func testNormalizationPreservesLeadingZeroAndKeepsOnlyFourASCIIDigits() {
        XCTAssertEqual(FocusSession.normalizedCode(" 0-1٢23 4"), "0123")
    }
}
