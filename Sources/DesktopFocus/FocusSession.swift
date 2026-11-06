import Foundation

enum UnlockResult: Equatable {
    case ignored
    case incorrect
    case unlocked
}

struct FocusSession {
    static let codeLength = 4

    let unlockCode: String
    private let deadline: Date
    private var cooldownDeadline: Date?
    private var wrongAttempts = 0

    init(duration: TimeInterval, startedAt: Date, unlockCode: String) {
        self.deadline = startedAt.addingTimeInterval(duration)
        self.unlockCode = unlockCode
    }

    func remaining(at now: Date) -> TimeInterval {
        max(0, deadline.timeIntervalSince(now))
    }

    func cooldownRemaining(at now: Date) -> TimeInterval {
        max(0, cooldownDeadline?.timeIntervalSince(now) ?? 0)
    }

    mutating func attemptUnlock(code: String, at now: Date) -> UnlockResult {
        guard remaining(at: now) > 0, cooldownRemaining(at: now) == 0,
              code.count == Self.codeLength, code == Self.normalizedCode(code) else {
            return .ignored
        }
        guard code != unlockCode else { return .unlocked }

        wrongAttempts += 1
        if wrongAttempts == 3 {
            cooldownDeadline = now.addingTimeInterval(60)
            wrongAttempts = 0
        }
        return .incorrect
    }

    static func normalizedCode(_ input: String) -> String {
        String(input.filter { $0.isASCII && $0.isNumber }.prefix(codeLength))
    }
}
