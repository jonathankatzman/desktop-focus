import Foundation

enum UnlockResult: Equatable {
    case ignored
    case incorrect
    case unlocked
}

struct FocusSession {
    static let codeLength = 4

    let unlockCode: String
    private let deadline: ContinuousClock.Instant
    private var cooldownDeadline: ContinuousClock.Instant?
    private var wrongAttempts = 0

    init(duration: TimeInterval, startedAt: ContinuousClock.Instant, unlockCode: String) {
        self.deadline = startedAt.advanced(by: .seconds(duration))
        self.unlockCode = unlockCode
    }

    func remaining(at now: ContinuousClock.Instant) -> TimeInterval {
        secondsRemaining(until: deadline, at: now)
    }

    func cooldownRemaining(at now: ContinuousClock.Instant) -> TimeInterval {
        guard let cooldownDeadline else { return 0 }
        return secondsRemaining(until: cooldownDeadline, at: now)
    }

    mutating func attemptUnlock(code: String, at now: ContinuousClock.Instant) -> UnlockResult {
        guard remaining(at: now) > 0, cooldownRemaining(at: now) == 0,
              code.count == Self.codeLength, code == Self.normalizedCode(code) else {
            return .ignored
        }
        guard code != unlockCode else { return .unlocked }

        wrongAttempts += 1
        if wrongAttempts == 3 {
            cooldownDeadline = now.advanced(by: .seconds(60))
            wrongAttempts = 0
        }
        return .incorrect
    }

    static func normalizedCode(_ input: String) -> String {
        String(input.filter { $0.isASCII && $0.isNumber }.prefix(codeLength))
    }

    private func secondsRemaining(until deadline: ContinuousClock.Instant, at now: ContinuousClock.Instant) -> TimeInterval {
        guard now < deadline else { return 0 }
        let duration = now.duration(to: deadline).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }
}
