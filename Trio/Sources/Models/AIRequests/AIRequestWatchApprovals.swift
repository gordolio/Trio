import Foundation

/// The requests the wearer approved on the watch, from the approval screen or from a notification, each with its
/// request's `expiresAt`. The watch keeps them in `UserDefaults`, so that after a relaunch it still knows a result is
/// for an approval of its own and posts it. Each is dropped `keptAfterExpiry` after its request expired: the phone's
/// result comes at the expiry at the latest, and a watch that was out of reach gets it later.
struct AIRequestWatchApprovals: Codable, Equatable {
    struct Approval: Codable, Equatable {
        let expiresAt: Date
        /// Approved from a notification action, with no screen to show the result.
        let fromNotification: Bool
    }

    /// Where the watch keeps them.
    static let defaultsKey = "AIRequests.watchApprovals"
    /// As long as the phone keeps a request's final report.
    static let keptAfterExpiry: TimeInterval = 24 * 60 * 60

    private var byID: [String: Approval] = [:]

    init() {}

    /// The wearer approved `id` at `now`. An approval from a notification stays one if the request is approved again.
    /// Approvals past keeping are dropped.
    mutating func add(_ id: String, expiresAt: Date, fromNotification: Bool, at now: Date) {
        prune(at: now)
        let wasFromNotification = byID[id]?.fromNotification ?? false
        byID[id] = Approval(expiresAt: expiresAt, fromNotification: fromNotification || wasFromNotification)
    }

    func contains(_ id: String) -> Bool {
        byID[id] != nil
    }

    func isFromNotification(_ id: String) -> Bool {
        byID[id]?.fromNotification ?? false
    }

    /// Drops the approvals whose request expired `keptAfterExpiry` or more before `now`.
    mutating func prune(at now: Date) {
        byID = byID.filter { now < $0.value.expiresAt.addingTimeInterval(Self.keptAfterExpiry) }
    }

    /// The approvals kept in `defaults`, without those past keeping at `now`. Nothing kept, or something that can't be
    /// read, is none.
    static func load(from defaults: UserDefaults, at now: Date) -> AIRequestWatchApprovals {
        guard let data = defaults.data(forKey: defaultsKey),
              var approvals = try? JSONDecoder().decode(AIRequestWatchApprovals.self, from: data)
        else { return AIRequestWatchApprovals() }
        approvals.prune(at: now)
        return approvals
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
