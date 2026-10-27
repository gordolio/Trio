import Combine
import Foundation
import UserNotifications

/// Fetches what the service has waiting for Trio and hands it to the coordinator. Trio checks in on the
/// service's pushes, on every loop run, which picks up a push that never arrived, whenever the watch reaches the
/// iPhone or Trio comes to the front, and when the wearer opens a request Trio hasn't seen yet. iOS can hold a push
/// back for minutes, but it lets Trio run when the watch messages it or the wearer opens Trio.
final class AIAssistantsCheckIn {
    enum Reason: String {
        case push
        case loop
        case watch = "watch contact"
        case foreground
        case open = "request opened"

        /// The watch messages the iPhone often, and Trio comes to the front often: these check in at most once per
        /// `throttle`. The others always check in.
        var isThrottled: Bool { self == .watch || self == .foreground }
    }

    /// The least time between two throttled check-ins.
    static let throttle: TimeInterval = 15
    /// How long to wait before each try again of an inbox fetch that failed for a reason other than signing out.
    static let defaultRetryDelays: [TimeInterval] = [1, 2, 4]

    private let api: AIAssistantsAPIClient
    private let coordinator: AIRequestCoordinator
    private let isLinked: () -> Bool
    private let beginBackgroundActivity: (String) -> () -> Void
    private let removeDeliveredCheckIns: () -> Void
    private let retryDelays: [TimeInterval]
    private let now: () -> Date
    private var subscription: AnyCancellable?

    private let lock = NSLock()
    private var isCheckingIn = false
    private var checkInRequested = false
    /// Set while unlinking: no check-in starts.
    private var isPaused = false
    /// Unlinks, and opens of a request Trio hasn't seen, waiting for the check-in in flight to finish.
    private var waitingForCheckIn: [CheckedContinuation<Void, Never>] = []
    /// When the last check-in started, for the throttle.
    private var lastStart: Date?

    init(
        api: AIAssistantsAPIClient,
        coordinator: AIRequestCoordinator,
        isLinked: @escaping () -> Bool,
        loopRuns: AnyPublisher<Date, Never>,
        beginBackgroundActivity: @escaping (String) -> () -> Void,
        removeDeliveredCheckIns: @escaping () -> Void,
        retryDelays: [TimeInterval] = AIAssistantsCheckIn.defaultRetryDelays,
        now: @escaping () -> Date = Date.init
    ) {
        self.api = api
        self.coordinator = coordinator
        self.isLinked = isLinked
        self.beginBackgroundActivity = beginBackgroundActivity
        self.removeDeliveredCheckIns = removeDeliveredCheckIns
        self.retryDelays = retryDelays
        self.now = now
        subscription = loopRuns.sink { [weak self] _ in
            Task { await self?.checkIn(reason: .loop) }
        }
    }

    /// Unless Trio is linked, this only removes the delivered check-in pushes: the service keeps sending them to a
    /// phone it has registered, for example after Trio was signed out. While a check-in is running, this only asks
    /// for one more after it, so a push and a loop run that arrive together fetch the inbox twice, one after the other.
    /// With `waitingForRunning`, it returns once that check-in, and the one more after it, have finished, so the
    /// caller sees what they brought in: an open of a request Trio hasn't seen waits like this.
    func checkIn(reason: Reason, waitingForRunning: Bool = false) async {
        guard isLinked() else {
            removeDeliveredCheckIns()
            return
        }
        switch startCheckIn(reason: reason) {
        case .started:
            break
        case .throttled:
            return
        case .running:
            if waitingForRunning { await waitForRunningCheckIn() }
            return
        }
        let endActivity = beginBackgroundActivity("AI Assistants check-in")
        defer { endActivity() }
        debug(.remote, "AI requests: checking in after a \(reason.rawValue)")
        repeat {
            let signedIn = await checkInOnce()
            removeDeliveredCheckIns()
            guard signedIn else {
                stopCheckIns()
                return
            }
        } while checkInAgain()
    }

    /// Starts no check-in until `resume()`, and waits for the one in flight. Unlinking calls it, so a check-in
    /// can't refresh the tokens while they're being cleared, or use up the refresh token the unlink needs.
    func pause() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                isPaused = true
                checkInRequested = false
                guard isCheckingIn else { return true }
                waitingForCheckIn.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func resume() {
        lock.withLock { isPaused = false }
    }

    /// Waits for the check-in in flight, if any, to finish.
    private func waitForRunningCheckIn() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                guard isCheckingIn else { return true }
                waitingForCheckIn.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    /// The inbox, fetched again after each of `retryDelays` when the fetch fails for any reason but signing out.
    /// Fetching it is safe to repeat. `nil` when every try failed.
    private func fetchInbox() async throws -> AIInbox? {
        var delays = retryDelays[...]
        while true {
            do {
                return try await api.getInbox()
            } catch AIAssistantsAPIError.signedOut {
                throw AIAssistantsAPIError.signedOut
            } catch {
                guard let delay = delays.popFirst() else {
                    debug(.remote, "AI requests: check-in failed, trying again at the next one: \(error)")
                    return nil
                }
                debug(.remote, "AI requests: check-in failed, trying again in \(delay) s: \(error)")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// Returns `false` if Trio was signed out, which ends the check-in; the API client tells the service. Any other
    /// error is tried again a few times, then waits for the next check-in.
    private func checkInOnce() async -> Bool {
        let inbox: AIInbox
        do {
            guard let fetched = try await fetchInbox() else { return true }
            inbox = fetched
        } catch {
            debug(.remote, "AI requests: check-in stopped, signed out")
            return false
        }

        for request in inbox.requests.sorted(by: { $0.createdAt < $1.createdAt }) {
            let meal = inbox.mealRequest(request)
            if request.withdrawn {
                await coordinator.withdraw(id: request.id, request: meal, via: .service)
            } else if let meal {
                await coordinator.receive(meal, via: .service)
            } else {
                debug(.remote, "AI requests: skipped \(request.id), it isn't a meal Trio can read")
            }
        }
        await coordinator.expireIfDue()
        return true
    }

    private enum Start {
        case started
        /// Paused, or a throttled reason too soon after the last check-in.
        case throttled
        /// A check-in is running; it runs once more after this one.
        case running
    }

    private func startCheckIn(reason: Reason) -> Start {
        lock.withLock {
            if isPaused {
                return .throttled
            }
            if isCheckingIn {
                checkInRequested = true
                return .running
            }
            let now = now()
            if reason.isThrottled, let lastStart, now.timeIntervalSince(lastStart) < Self.throttle {
                return .throttled
            }
            isCheckingIn = true
            lastStart = now
            return .started
        }
    }

    private func checkInAgain() -> Bool {
        let (again, unlinks) = lock.withLock {
            if checkInRequested {
                checkInRequested = false
                return (true, [CheckedContinuation<Void, Never>]())
            }
            isCheckingIn = false
            defer { waitingForCheckIn = [] }
            return (false, waitingForCheckIn)
        }
        unlinks.forEach { $0.resume() }
        return again
    }

    /// Drops a check-in asked for meanwhile, too.
    private func stopCheckIns() {
        let unlinks = lock.withLock {
            checkInRequested = false
            isCheckingIn = false
            defer { waitingForCheckIn = [] }
            return waitingForCheckIn
        }
        unlinks.forEach { $0.resume() }
    }

    /// Removes the check-in pushes from Notification Center: the quiet alert stays there otherwise.
    static func removeDeliveredCheckIns() {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notifications in
            let ids = notifications
                .filter { AIRequestHooks.isCheckIn($0.request.content.userInfo) }
                .map(\.request.identifier)
            guard !ids.isEmpty else { return }
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }
}
