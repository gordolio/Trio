import Combine
import SwiftUI
import Swinject

extension PendingAIRequest: Identifiable {
    var id: String { request.id }
}

/// Decides which request the approval screen shows. A tap on the iPhone backup opens the pending request it
/// was for, and so does opening Trio once the iPhone is asking for it. The screen goes away as soon as that
/// request is no longer the pending one: it was answered on the watch, expired, withdrawn or replaced.
@MainActor final class AIRequestPhoneApprovalPresenter: ObservableObject {
    static let shared = AIRequestPhoneApprovalPresenter()

    /// The request the approval screen shows.
    @Published var presented: PendingAIRequest?

    /// Whether the iPhone is asking for the request now, rather than the watch alone.
    private let isBackupDue: (PendingAIRequest) async -> Bool
    /// The request whose notification was tapped, or that was due when Trio opened, until the coordinator has it
    /// as pending. A tap that launched Trio comes before the coordinator has read its pending request from disk.
    private var tappedID: String?
    /// The coordinator's pending request, as last received here.
    private var latest: PendingAIRequest?
    private var subscription: AnyCancellable?

    init(isBackupDue: @escaping (PendingAIRequest) async -> Bool = { await AIRequestPhoneBackup().isDue($0) }) {
        self.isBackupDue = isBackupDue
    }

    /// Shows the request a tapped notification was for, once it is the pending one.
    func open(requestID: String) {
        tappedID = requestID
        followCoordinator()
        presentTappedRequest()
    }

    /// Shows the pending request when Trio comes to the front, if the iPhone is asking for it, so it doesn't take a
    /// tap on a notification that was cleared, grouped or lost on a cold launch.
    func presentDueRequest() async {
        guard let coordinator = AIRequestsRuntime.shared?.coordinator else { return }
        followCoordinator()
        // Reads the pending request from disk first, and drops it if its time is up.
        await coordinator.expireIfDue()
        await presentIfDue(coordinator.current.value)
    }

    /// Shows `pending` as if its notification was tapped, unless the watch is still asking for it alone.
    func presentIfDue(_ pending: PendingAIRequest?) async {
        guard let pending, presented == nil, await isBackupDue(pending) else { return }
        open(requestID: pending.request.id)
    }

    /// Follows the coordinator's pending request. Does nothing if it already does, or the coordinator isn't
    /// there yet.
    func followCoordinator() {
        guard subscription == nil, let coordinator = AIRequestsRuntime.shared?.coordinator else { return }
        follow(coordinator.current.eraseToAnyPublisher())
    }

    /// The coordinator publishes on its own executor, and is briefly empty while one request replaces another,
    /// so the changes are received on the main queue and each one is checked against what is shown.
    func follow(_ current: AnyPublisher<PendingAIRequest?, Never>) {
        subscription = current
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pending in
                MainActor.assumeIsolated { self?.currentChanged(pending) }
            }
    }

    private func currentChanged(_ pending: PendingAIRequest?) {
        latest = pending
        if let presented, presented.request.id != pending?.request.id {
            self.presented = nil
        }
        presentTappedRequest()
    }

    private func presentTappedRequest() {
        guard let tappedID, let latest, latest.request.id == tappedID else { return }
        presented = latest
        self.tappedID = nil
    }
}

/// The approval screen's answers to the request it shows. Approving needs Face ID or the passcode, the same check as
/// an in-app bolus, because an unlocked phone doesn't prove who is holding it.
struct AIRequestPhoneApprovalFlow {
    let requestID: String
    private let unlock: () async throws -> Bool
    private let answer: (AIRequestAnswerSource) async -> Void

    init(
        requestID: String,
        unlock: @escaping () async throws -> Bool,
        answer: @escaping (AIRequestAnswerSource) async -> Void
    ) {
        self.requestID = requestID
        self.unlock = unlock
        self.answer = answer
    }

    /// Trio's Face ID check, and the coordinator.
    static func live(requestID: String) -> AIRequestPhoneApprovalFlow {
        AIRequestPhoneApprovalFlow(
            requestID: requestID,
            unlock: {
                guard let unlockManager = TrioApp.resolver.resolve(UnlockManager.self) else { return false }
                return try await unlockManager.unlock()
            },
            answer: { source in
                guard let coordinator = AIRequestsRuntime.shared?.coordinator else { return }
                let outcome = await coordinator.answer(source)
                debug(.service, "AI requests: the iPhone answer to \(requestID) was \(outcome)")
            }
        )
    }

    /// Returns whether it approved. A failed, cancelled or unavailable Face ID answers nothing, and the request
    /// stays pending.
    func approve() async -> Bool {
        do {
            guard try await unlock() else { return false }
        } catch {
            debug(.service, "AI requests: Face ID didn't pass for \(requestID): \(error)")
            return false
        }
        await answer(.phone(.approve, id: requestID))
        return true
    }

    func decline() async {
        await answer(.phone(.decline, id: requestID))
    }
}

/// Asks the wearer to approve or decline a request on the iPhone.
struct AIRequestPhoneApprovalView: View {
    let pending: PendingAIRequest
    let flow: AIRequestPhoneApprovalFlow

    @Environment(\.dismiss) private var dismiss
    /// Face ID or the answer is under way, so a second tap doesn't start another.
    @State private var isWorking = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            VStack(spacing: 12) {
                Image(systemName: "fork.knife")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(pending.prompt.title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(pending.prompt.body)
                    .font(.body)
                    .multilineTextAlignment(.center)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Expires in \(Self.countdown(until: pending.prompt.expiresAt, now: context.date))")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }

            Spacer(minLength: 0)

            VStack(spacing: 12) {
                Button {
                    approve()
                } label: {
                    Label("Approve with Face ID", systemImage: "faceid")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    decline()
                } label: {
                    Text("Decline")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .disabled(isWorking)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .interactiveDismissDisabled(isWorking)
        .presentationDetents([.medium, .large])
    }

    /// The time left as `m:ss`, never below `0:00`.
    static func countdown(until expiresAt: Date, now: Date) -> String {
        let seconds = max(0, Int(expiresAt.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// A failed or cancelled Face ID changes nothing: the request stays pending and the screen stays open.
    private func approve() {
        guard !isWorking else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            guard await flow.approve() else { return }
            dismiss()
        }
    }

    private func decline() {
        guard !isWorking else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            await flow.decline()
            dismiss()
        }
    }
}

extension View {
    /// Shows the approval screen over the app when the wearer opens the iPhone backup notification, or opens Trio
    /// while the iPhone is asking.
    func aiRequestPhoneApproval() -> some View {
        modifier(AIRequestPhoneApprovalModifier())
    }
}

private struct AIRequestPhoneApprovalModifier: ViewModifier {
    @ObservedObject private var presenter = AIRequestPhoneApprovalPresenter.shared
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .sheet(item: $presenter.presented) { pending in
                AIRequestPhoneApprovalView(pending: pending, flow: .live(requestID: pending.request.id))
            }
            // The coordinator is there by the time the app shows, and a tap that launched Trio waits for it. On a
            // cold launch the scene is already active when the app shows, so its phase doesn't change.
            .onAppear {
                presenter.followCoordinator()
                if scenePhase == .active {
                    Task { await presenter.presentDueRequest() }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await presenter.presentDueRequest() }
                }
            }
    }
}
