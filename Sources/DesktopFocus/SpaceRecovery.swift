import Foundation

final class SpaceRecovery {
    private let retryInterval: TimeInterval
    private var timer: Timer?
    private var attemptsRemaining = 0

    init(retryInterval: TimeInterval = 0.15) {
        self.retryInterval = retryInterval
    }

    deinit {
        timer?.invalidate()
    }

    func recoverIfNeeded(
        isOnTargetSpace: @escaping () -> Bool,
        returnToTargetSpace: @escaping () -> Void
    ) {
        if isOnTargetSpace() {
            cancel()
            return
        }
        guard timer == nil else { return }

        attemptsRemaining = 4
        let timer = Timer(timeInterval: retryInterval, repeats: true) { [weak self] timer in
            guard let self, self.timer === timer else { return }
            guard !isOnTargetSpace() else {
                self.cancel()
                return
            }

            self.attemptsRemaining -= 1
            returnToTargetSpace()

            // Activating a window can trigger another Space notification.
            if self.timer === timer, self.attemptsRemaining == 0 {
                self.cancel()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        timer.fire()
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}
