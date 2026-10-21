import Combine
import LocalAuthentication
import SwiftUI
import Swinject

extension PendingAIRequest: Identifiable {
    var id: String { request.id }
}

/// Decides which request the approval sheet shows, and what it shows for it. A tap on the iPhone backup opens the
/// pending request it was for, and so does opening Trio once the iPhone is asking for it. The sheet then stays until
/// the wearer closes it. When the request ends, whether it was answered here or on the watch, expired, withdrawn or
/// replaced, the coordinator's outcome for it becomes `result`, and the sheet shows that in place of the buttons. Only
/// `close()` takes the request off, so the wearer always sees how it ended.
@MainActor final class AIRequestPhoneApprovalPresenter: ObservableObject {
    static let shared = AIRequestPhoneApprovalPresenter()

    /// The request the approval sheet shows. It stays set after the request leaves pending, until `close()`.
    @Published private(set) var presented: PendingAIRequest?
    /// How the presented request ended, once it has.
    @Published private(set) var result: AIRequestResultMessage?

    /// Whether the iPhone is asking for the request now, rather than the watch alone.
    private let isBackupDue: (PendingAIRequest) async -> Bool
    /// The coordinator, once the runtime has made it.
    private let coordinator: () -> AIRequestCoordinator?
    /// The request whose notification was tapped, or that was due when Trio opened, until the coordinator has it
    /// as pending. A tap that launched Trio comes before the coordinator has read its pending request from disk.
    private var tappedID: String?
    /// The coordinator's pending request, as last received here.
    private var latest: PendingAIRequest?
    private var subscription: AnyCancellable?
    private var outcomeSubscription: AnyCancellable?

    init(
        isBackupDue: @escaping (PendingAIRequest) async -> Bool = {
            await AIRequestPhoneBackup().isDue($0, now: Date())
        },
        coordinator: @escaping () -> AIRequestCoordinator? = { AIRequestsRuntime.shared?.coordinator }
    ) {
        self.isBackupDue = isBackupDue
        self.coordinator = coordinator
    }

    /// Shows the request a tapped notification was for, once it is the pending one.
    func open(requestID: String) {
        tappedID = requestID
        followCoordinator()
        presentTappedRequest()
    }

    /// Shows the pending request when Trio comes to the front, if the iPhone is asking for it, so it doesn't take a
    /// tap on a notification that was cleared, grouped or lost on a cold launch. Without a coordinator, it's the
    /// request last received here.
    func presentDueRequest() async {
        var candidate = latest
        if let coordinator = coordinator() {
            followCoordinator()
            // Reads the pending request from disk first, and drops it if its time is up.
            await coordinator.expireIfDue()
            candidate = coordinator.current.value
        }
        await presentIfDue(candidate)
    }

    /// Shows `pending` as if its notification was tapped, unless the watch is still asking for it alone, or the sheet
    /// is already showing a request.
    func presentIfDue(_ pending: PendingAIRequest?) async {
        guard let pending, presented == nil, await isBackupDue(pending) else { return }
        open(requestID: pending.request.id)
    }

    /// Takes the sheet away with its result, then shows the next request that is waiting on the iPhone, if there is
    /// one: the request that replaced the one the sheet was showing, say. Done comes here, and so does swiping a
    /// result away. The task is the search for that next request, which the caller needn't wait for.
    @discardableResult func close() -> Task<Void, Never> {
        presented = nil
        result = nil
        // A tap on the next request's notification, made while the sheet was showing this one.
        presentTappedRequest()
        return Task { await presentDueRequest() }
    }

    /// Follows the coordinator's pending request and outcomes. Does nothing if it already does, or the coordinator
    /// isn't there yet.
    func followCoordinator() {
        guard subscription == nil, let coordinator = coordinator() else { return }
        follow(coordinator.current.eraseToAnyPublisher(), outcomes: coordinator.outcomes.eraseToAnyPublisher())
    }

    /// The coordinator publishes on its own executor, and is briefly empty while one request replaces another, so the
    /// changes are received on the main queue and each one is checked against what is shown. A request that leaves
    /// pending takes nothing off the sheet: its outcome follows, and the sheet shows it.
    func follow(
        _ current: AnyPublisher<PendingAIRequest?, Never>,
        outcomes: AnyPublisher<AIRequestOutcome, Never>
    ) {
        subscription = current
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pending in
                MainActor.assumeIsolated { self?.currentChanged(pending) }
            }
        outcomeSubscription = outcomes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] outcome in
                MainActor.assumeIsolated { self?.outcomeArrived(outcome) }
            }
    }

    private func currentChanged(_ pending: PendingAIRequest?) {
        latest = pending
        presentTappedRequest()
    }

    /// Only the presented request's outcome counts. One for a request the sheet isn't showing has nobody to show it to.
    private func outcomeArrived(_ outcome: AIRequestOutcome) {
        guard presented?.request.id == outcome.id else { return }
        result = AIRequestResultText.message(for: outcome)
    }

    /// Shows the tapped request once it is the pending one, unless the sheet is showing another: its result stays
    /// until the wearer closes it, and `close()` comes back here.
    private func presentTappedRequest() {
        guard presented == nil, let tappedID, let latest, latest.request.id == tappedID else { return }
        presented = latest
        self.tappedID = nil
    }
}

/// The approval screen's answers to the request it shows. Approving needs Face ID or the passcode, the same check as
/// an in-app bolus, because an unlocked phone doesn't prove who is holding it. The prompt names the dose.
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

    /// Face ID with the dose in its reason, and the coordinator. `shown` is what the request asks for.
    static func live(requestID: String, shown: AIRequestShown) -> AIRequestPhoneApprovalFlow {
        AIRequestPhoneApprovalFlow(
            requestID: requestID,
            unlock: {
                try await AIRequestUnlock.unlock(reason: AIRequestUnlock.reason(shown: shown))
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
    @discardableResult func approve() async -> Bool {
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

/// The haptic the approval sheet plays when its request ends, as a plain value so the map from a result to a haptic can be
/// tested. `feedback` is what `.sensoryFeedback` plays.
enum AIRequestPhoneHaptic: Equatable {
    /// The request was carried out.
    case success
    /// The request was refused and nothing was logged.
    case error
    /// The carbs were logged but the bolus wasn't, or may not have been, or the request ended with nobody answering.
    case warning
    /// The wearer declined, here or on the watch.
    case lightImpact

    /// A result's haptic follows its tone. A neutral result is either a decline, which somebody answered, or a request
    /// that ended with nobody answering (expired, replaced or canceled), which warns.
    init(result message: AIRequestResultMessage) {
        switch message.tone {
        case .success:
            self = .success
        case .failure:
            self = .error
        case .warning:
            self = .warning
        case .neutral:
            self = message.answeredOn == nil ? .warning : .lightImpact
        }
    }

    var feedback: SensoryFeedback {
        switch self {
        case .success:
            return .success
        case .error:
            return .error
        case .warning:
            return .warning
        case .lightImpact:
            return .impact(weight: .light)
        }
    }
}

/// Where the approval sheet is.
enum AIRequestPhoneApprovalPhase: Equatable {
    /// The request waits for the wearer's answer.
    case asking
    /// Face ID and the answer are under way.
    case checking
    /// The request ended, and this is how.
    case result(AIRequestResultMessage)

    /// A result for another request doesn't count. A result takes over from `isWorking`: the watch can answer while
    /// Face ID is up.
    init(result: AIRequestResultMessage?, requestID: String, isWorking: Bool) {
        if let result, result.id == requestID {
            self = .result(result)
        } else {
            self = isWorking ? .checking : .asking
        }
    }

    /// Only a result lets the sheet be swiped away. Until then the request is waiting for an answer, and the sheet
    /// can only be closed by giving one.
    var allowsSwipeToDismiss: Bool {
        if case .result = self { return true }
        return false
    }

    /// The haptic for moving to this phase from `old`. Only a result has one, and only on arrival: asking, checking and
    /// going back to asking after a Face ID that didn't pass are silent, because Face ID has its own.
    func haptic(after old: AIRequestPhoneApprovalPhase) -> AIRequestPhoneHaptic? {
        guard case let .result(message) = self, old != self else { return nil }
        return AIRequestPhoneHaptic(result: message)
    }

    /// The heights the sheet may take. While it asks, it's the full height whenever a double-dose warning is among
    /// Trio's rows or the text is at an accessibility size, so Approve is never in reach with a warning cut off. Without
    /// either, a half sheet is enough. A result can be pulled up to the full height as well, since what it says is
    /// whether insulin was given.
    func detents(hasWarning: Bool, isAccessibilitySize: Bool) -> Set<PresentationDetent> {
        switch self {
        case .asking,
             .checking:
            return hasWarning || isAccessibilitySize ? [.large] : [.medium]
        case .result:
            return [.medium, .large]
        }
    }
}

/// Asks the wearer to approve or decline a request on the iPhone, and then shows how it ended. The sheet stays until
/// the wearer presses Done or swipes it away, which only a result allows.
///
/// While it asks, the amounts come first, in two columns, because they are what the wearer is approving: the dose and
/// the carbs, as `pending.prompt.shown` has them. The title, Trio's context rows (`AIRequestContextRows`, as on the
/// watch and in the notification), the time left and what Approve does follow, and the buttons stay at the bottom.
/// The look is Trio's: a `Form` on `Color.chart` rows, over `AppState`'s background, tinted `Color.tabBar`.
struct AIRequestPhoneApprovalView: View {
    let pending: PendingAIRequest
    /// How the request ended, once it has. The presenter has it from the coordinator's outcomes, and it can come
    /// from an answer given on the watch.
    let result: AIRequestResultMessage?
    let flow: AIRequestPhoneApprovalFlow
    /// What the device unlocks with, which picks the Approve button's icon.
    let biometryType: LABiometryType
    /// Closes the sheet.
    let done: () -> Void

    /// The answer that is under way, if one is: Face ID and the answer for Approve, the answer alone for Decline. A
    /// second tap doesn't start another.
    @State private var working: Answer?
    /// Whether the result's icon has moved on from the meal icon the request began with. It flips as the result appears,
    /// so the icon is replaced (P6, P7, P9) and then bounces.
    @State private var iconShowsResult = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppState.self) private var appState

    private enum Answer {
        case approve
        case decline
    }

    private var phase: AIRequestPhoneApprovalPhase {
        AIRequestPhoneApprovalPhase(result: result, requestID: pending.request.id, isWorking: working != nil)
    }

    private var shown: AIRequestShown { pending.prompt.shown }

    /// How the request gives way to its result, and the result to the buttons' Done. Under Reduce Motion it only fades.
    private var phaseTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94))
    }

    var body: some View {
        Group {
            switch phase {
            case .asking,
                 .checking:
                requestForm
                    .transition(phaseTransition)
            case let .result(message):
                resultScroll(message)
                    .transition(phaseTransition)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            buttons
        }
        .background(appState.trioBackgroundColor(for: colorScheme).ignoresSafeArea())
        .tint(Color.tabBar)
        // P6 to P10: the request gives way to its result, and a result to the next, in 0.35 s without a bounce.
        .animation(.smooth(duration: 0.35), value: phase)
        // The one haptic map. A result plays its haptic once, when it arrives, whoever answered.
        .sensoryFeedback(trigger: phase) { old, new in
            new.haptic(after: old)?.feedback
        }
        // The buttons the wearer was on are gone when the result shows, so VoiceOver says what happened.
        .onChange(of: phase) { _, new in
            if case let .result(message) = new {
                AccessibilityNotification.Announcement(Self.spoken(result: message)).post()
            }
        }
        .interactiveDismissDisabled(!phase.allowsSwipeToDismiss)
        .presentationDetents(phase.detents(
            hasWarning: contextRowList.contains(where: \.isWarning),
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
        ))
    }

    // MARK: Asking

    /// The amounts, then the title, Trio's context and the time left, with what Approve does under them.
    private var requestForm: some View {
        Form {
            Section {
                amounts
            }
            .listRowBackground(Color.chart)

            Section {
                Text(pending.prompt.title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                contextRows
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let secondsLeft = Self.secondsLeft(until: pending.prompt.expiresAt, now: context.date)
                    // P3: the digits roll down each second, and the line turns orange for the last minute. Under
                    // Reduce Motion they change without rolling.
                    Text("Expires in \(Self.countdown(secondsLeft: secondsLeft))")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(
                            Self.isUrgent(secondsLeft: secondsLeft) ? AnyShapeStyle(Color.orange) :
                                AnyShapeStyle(HierarchicalShapeStyle.secondary)
                        )
                        .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
                        .animation(.snappy(duration: 0.3), value: secondsLeft)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            } footer: {
                if let approveLine {
                    Text(approveLine)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }
            }
            .listRowBackground(Color.chart)
        }
        .scrollContentBackground(.hidden)
        .scrollBounceBehavior(.basedOnSize)
    }

    /// The dose and the carbs side by side, as big as anything on the sheet. Where they don't fit side by side, they
    /// stack. An amount is never scaled or cut. The fat and protein, when there are any, are under them.
    private var amounts: some View {
        VStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    insulinColumn
                    carbsColumn
                }
                VStack(spacing: 12) {
                    insulinColumn
                    carbsColumn
                }
            }
            if let fatAndProtein = shown.fatAndProteinText {
                Text(fatAndProtein)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var insulinColumn: some View {
        amountColumn(
            Text("Insulin", comment: "iPhone approval: label over Trio's dose"),
            value: shown.unitsText,
            color: Color.insulin,
            spoken: shown.spokenInsulin
        )
    }

    private var carbsColumn: some View {
        amountColumn(
            Text("Carbs", comment: "iPhone approval: label over the carbs"),
            value: shown.carbsText,
            color: .orange,
            spoken: shown.spokenCarbs
        )
    }

    /// A label over its amount. VoiceOver reads the pair as one element, as `spoken`: "Insulin, 2.10 units", with the
    /// unit spelled out where the screen has its letter.
    private func amountColumn(_ label: Text, value: String, color: Color, spoken: String) -> some View {
        VStack(spacing: 2) {
            label
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title.bold().monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
    }

    /// Trio's rows for the request, the same as on the watch and in the notification.
    private var contextRowList: [AIRequestContextRow] {
        AIRequestContextRows.rows(
            context: pending.prompt.context,
            shown: shown,
            testKind: pending.prompt.testKind
        )
    }

    /// The rows, a warning with an orange triangle. The watch's is yellow, which doesn't read on a light row, and the
    /// triangle is all that marks a row as a warning. The words stay in the primary color.
    @ViewBuilder private var contextRows: some View {
        let rows = contextRowList
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            Group {
                if row.isWarning {
                    Label {
                        Text(row.text)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text(row.text)
                }
            }
            .font(.subheadline)
        }
    }

    /// What approving does, or `nil` for a test that only goes through the motions: its own row says nothing is logged
    /// or given, and this line would say the opposite.
    private var approveLine: String? {
        guard pending.prompt.testKind != .dryRun else { return nil }
        if AIRequestContextRows.givesNoBolus(shown) {
            return String(
                localized: "Approving logs \(shown.carbsText) of carbs only.",
                comment: "iPhone approval: what Approve does when Trio's dose is 0 U. The placeholder is the carbs, for example '35 g'."
            )
        }
        return String(
            localized: "Approving logs \(shown.carbsText) of carbs and starts a \(shown.unitsText) bolus.",
            comment: "iPhone approval: what Approve does. The placeholders are the carbs, for example '35 g', and the dose, for example '2.10 U'."
        )
    }

    // MARK: Buttons

    /// The answer buttons while it asks, and Done once there's a result. They stay at the bottom while the rest scrolls.
    private var buttons: some View {
        Group {
            switch phase {
            case .asking,
                 .checking:
                answerButtons
                    .transition(.opacity)
            case .result:
                doneButton
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    /// The button that is working shows it, and keeps its full strength. The other one is disabled, and a second tap on
    /// the working one is ignored.
    private var answerButtons: some View {
        let approveLabel = AIRequestUnlock.approveLabel(shown: shown, biometryType: biometryType)
        return VStack(spacing: 12) {
            Button {
                answer(.approve)
            } label: {
                if working == .approve {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(.white)
                        Text("Checking…")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Label(approveLabel.title, systemImage: approveLabel.symbol)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(working == .decline)

            Button(role: .destructive) {
                answer(.decline)
            } label: {
                if working == .decline {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Declining…")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Text("Decline")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .disabled(working == .approve)
        }
        .controlSize(.large)
        // P4 and P5: the working button swaps its icon for the spinner, and back after a Face ID that didn't pass.
        .animation(.smooth(duration: 0.2), value: working)
    }

    private var doneButton: some View {
        Button {
            done()
        } label: {
            Text("Done")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    // MARK: Result

    /// The result, centered when it's short and scrolling when it's not: a long detail can say whether insulin was
    /// given, and mustn't run under the grabber or the Done button.
    private func resultScroll(_ message: AIRequestResultMessage) -> some View {
        GeometryReader { proxy in
            ScrollView {
                resultContent(message)
                    .padding(24)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// The icon, the headline and the detail. A request answered on the watch says so above them.
    private func resultContent(_ message: AIRequestResultMessage) -> some View {
        let look = Self.look(for: message.tone)
        return VStack(spacing: 12) {
            if message.answeredOn == .watch {
                Text("Answered on your watch")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            resultIcon(look)
            Text(message.headline)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(message.detail)
                .font(.body)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
    }

    /// The meal icon a request starts as, which a result's icon replaces.
    private static let requestSymbol = "fork.knife"

    /// The result's icon. It begins as the meal icon and is replaced by the result's symbol as the result appears (P6,
    /// P7, P9), which then bounces, unless the result is a decline or an end nobody answered. Under Reduce Motion it is
    /// the result's symbol from the start, and fades in with the rest.
    private func resultIcon(_ look: Look) -> some View {
        let showsResult = iconShowsResult || reduceMotion
        return Image(systemName: showsResult ? look.symbol : Self.requestSymbol)
            .font(.largeTitle)
            .foregroundStyle(showsResult ? look.color : Color.secondary)
            .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
            .symbolEffect(.bounce, value: look.bounces && !reduceMotion && iconShowsResult)
            .onAppear {
                withAnimation(.smooth(duration: 0.35)) {
                    iconShowsResult = true
                }
            }
            .accessibilityHidden(true)
    }

    private typealias Look = (symbol: String, color: Color, bounces: Bool)

    /// The icon of a result, the same as on the watch: only a success is a green check. A decline or an end nobody
    /// answered is quiet; a success, a warning and a failure bounce.
    private static func look(for tone: AIRequestResultMessage.Tone) -> Look {
        switch tone {
        case .success:
            return ("checkmark.circle.fill", .loopGreen, true)
        case .neutral:
            return ("xmark.circle", .secondary, false)
        case .warning:
            return ("exclamationmark.triangle.fill", .orange, true)
        case .failure:
            return ("exclamationmark.triangle.fill", .loopRed, true)
        }
    }

    /// The whole seconds left, rounded up, never below 0.
    static func secondsLeft(until expiresAt: Date, now: Date) -> Int {
        max(0, Int(expiresAt.timeIntervalSince(now).rounded(.up)))
    }

    /// The time left as `m:ss`, never below `0:00`.
    static func countdown(until expiresAt: Date, now: Date) -> String {
        countdown(secondsLeft: secondsLeft(until: expiresAt, now: now))
    }

    static func countdown(secondsLeft seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Whether the countdown turns orange: the last minute.
    static func isUrgent(secondsLeft: Int) -> Bool {
        secondsLeft <= 60
    }

    /// What VoiceOver says when the request ends: the headline, then what it means.
    static func spoken(result message: AIRequestResultMessage) -> String {
        "\(message.headline). \(message.detail)"
    }

    // MARK: Answering

    /// A failed or cancelled Face ID changes nothing: the request stays pending and the sheet stays as it was. An
    /// answer that goes through comes back as the result, which the presenter gets from the coordinator.
    private func answer(_ answer: Answer) {
        guard working == nil else { return }
        working = answer
        Task {
            defer { working = nil }
            switch answer {
            case .approve:
                await flow.approve()
            case .decline:
                await flow.decline()
            }
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

    /// The wearer can swipe the sheet away only once it shows a result, and that closes it as Done does. While the
    /// request is waiting for an answer the sheet isn't let go: the item stays, and so does the sheet.
    private var sheetItem: Binding<PendingAIRequest?> {
        Binding(
            get: { presenter.presented },
            set: { item in
                if item == nil, presenter.result != nil { presenter.close() }
            }
        )
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: sheetItem) { pending in
                AIRequestPhoneApprovalView(
                    pending: pending,
                    result: presenter.result,
                    flow: .live(requestID: pending.request.id, shown: pending.prompt.shown),
                    biometryType: AIRequestUnlock.currentBiometryType(),
                    done: { presenter.close() }
                )
                // A new request starts a new sheet: nothing the last one was doing carries over.
                .id(pending.request.id)
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
