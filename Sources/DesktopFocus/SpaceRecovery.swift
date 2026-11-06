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
        returnToTargetSpace: @escaping () -> Void,
        didFinish: @escaping (Bool) -> Void
    ) {
        if isOnTargetSpace() {
            cancel()
            didFinish(true)
            return
        }
        guard timer == nil else { return }

        attemptsRemaining = 4
        let timer = Timer(timeInterval: retryInterval, repeats: true) { [weak self] timer in
            guard let self, self.timer === timer else { return }
            let onTarget = isOnTargetSpace()
            // Give the last activation a retry interval to complete before reporting failure.
            if onTarget || self.attemptsRemaining == 0 {
                self.cancel()
                didFinish(onTarget)
                return
            }

            self.attemptsRemaining -= 1
            returnToTargetSpace()
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
