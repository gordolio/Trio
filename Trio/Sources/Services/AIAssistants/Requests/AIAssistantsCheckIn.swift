import Combine
import Foundation
import UserNotifications

/// Fetches what the service has waiting for Trio and hands it to the coordinator. Trio checks in on the
/// service's check-in push, and on every loop run, which picks up a push that never arrived.
final class AIAssistantsCheckIn {
    enum Reason: String {
        case push
        case loop
    }

    private let api: AIAssistantsAPIClient
    private let coordinator: AIRequestCoordinator
    private let isLinked: () -> Bool
    private let beginBackgroundActivity: (String) -> () -> Void
    private let removeDeliveredCheckIns: () -> Void
    private var subscription: AnyCancellable?

    private let lock = NSLock()
    private var isCheckingIn = false
    private var checkInRequested = false
    /// Set while unlinking: no check-in starts.
    private var isPaused = false
    /// Unlinks waiting for the check-in in flight to finish.
    private var waitingForCheckIn: [CheckedContinuation<Void, Never>] = []

    init(
        api: AIAssistantsAPIClient,
        coordinator: AIRequestCoordinator,
        isLinked: @escaping () -> Bool,
        loopRuns: AnyPublisher<Date, Never>,
        beginBackgroundActivity: @escaping (String) -> () -> Void,
        removeDeliveredCheckIns: @escaping () -> Void
    ) {
        self.api = api
        self.coordinator = coordinator
        self.isLinked = isLinked
        self.beginBackgroundActivity = beginBackgroundActivity
        self.removeDeliveredCheckIns = removeDeliveredCheckIns
        subscription = loopRuns.sink { [weak self] _ in
            Task { await self?.checkIn(reason: .loop) }
        }
    }

    /// Unless Trio is linked, this only removes the delivered check-in pushes: the service keeps sending them to a
    /// phone it has registered, for example after Trio was signed out. While a check-in is running, this only asks
    /// for one more after it, so a push and a loop run that arrive together fetch the inbox twice, one after the other.
    func checkIn(reason: Reason) async {
        guard isLinked() else {
            removeDeliveredCheckIns()
            return
        }
        guard startCheckIn() else { return }
        let endActivity = beginBackgroundActivity("AI Assistants check-in")
        defer { endActivity() }
        debug(.service, "AI requests: checking in after a \(reason.rawValue)")
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

    /// Returns `false` if Trio was signed out, which ends the check-in; the API client tells the service. Any other
    /// error waits for the next check-in.
    private func checkInOnce() async -> Bool {
        let inbox: AIInbox
        do {
            inbox = try await api.getInbox()
        } catch AIAssistantsAPIError.signedOut {
            debug(.service, "AI requests: check-in stopped, signed out")
            return false
        } catch {
            debug(.service, "AI requests: check-in failed, trying again at the next one: \(error)")
            return true
        }

        for request in inbox.requests.sorted(by: { $0.createdAt < $1.createdAt }) {
            let meal = inbox.mealRequest(request)
            if request.withdrawn {
                await coordinator.withdraw(id: request.id, request: meal, via: .service)
            } else if let meal {
                await coordinator.receive(meal, via: .service)
            } else {
                debug(.service, "AI requests: skipped \(request.id), it isn't a meal Trio can read")
            }
        }
        for answer in inbox.answers {
            _ = await coordinator.answer(.watch(answer))
        }
        await coordinator.expireIfDue()
        return true
    }

    /// False while paused, or while a check-in is running; that check-in then runs once more.
    private func startCheckIn() -> Bool {
        lock.withLock {
            if isPaused {
                return false
            }
            if isCheckingIn {
                checkInRequested = true
                return false
            }
            isCheckingIn = true
            return true
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
