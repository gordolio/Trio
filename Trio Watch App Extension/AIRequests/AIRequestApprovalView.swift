import Foundation
import SwiftUI
import WatchKit

/// The screen an AI assistant's request opens on the watch: what it asks for, the wearer's answer, and what became of
/// it. The wearer approves by turning the crown, or on watchOS 11 and later with Approve or a double tap, and declines
/// with the button. The screen has no X. Once it's answered, it closes itself only after an outcome the wearer can take
/// as read, and otherwise waits for Close. If the system still closes it while it's asking, that counts as a dismissal.
///
/// The carbs and dose come from `prompt.shown`, which is what the answer is signed against and what the phone checks
/// it for. The context rows are Trio's own (`AIRequestContextRows`, as in the notification), and show only when Trio's
/// signature over them checks out.
///
/// `AIRequestWatchFlow` holds the phases and the rules for each: how it ends, and when the countdown shows. The phone's
/// receipt and result move it on, and the clock only expires a request nobody has answered. Nothing sleeps:
/// `TimelineView`s tell the time, and the closing ring is an animation whose completion closes the screen.
struct AIRequestApprovalView: View {
    let prompt: AIRequestPrompt

    @State private var flow: AIRequestWatchFlow
    @State private var confirmationProgress = 0.0
    /// How much of the closing ring is left, from 1 to 0. The screen closes when it runs out.
    @State private var ringLeft = 1.0
    @State private var isClosing = false
    @FocusState private var isCrownFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    /// Whether Trio signed what the screen shows, so it can show the context rows. Worked out once: it reads the key.
    private let isDisplayVerified: Bool
    private let contextRows: [AIRequestContextRow]

    private let trioBackgroundColor = LinearGradient(
        gradient: Gradient(colors: [Color.bgDarkBlue, Color.bgDarkerDarkBlue]),
        startPoint: .top,
        endPoint: .bottom
    )

    init(prompt: AIRequestPrompt) {
        let center = AIRequestWatchCenter.shared
        let now = Date()
        var flow = AIRequestWatchFlow(shownAt: now, expiresAt: prompt.expiresAt)
        // A request whose result is already here starts from it, rather than asking again.
        if let result = center.results[prompt.id] {
            flow.resultArrived(result)
        }
        flow.expireIfDue(at: now)
        self.init(prompt: prompt, flow: flow, isDisplayVerified: center.isDisplayVerified(prompt))
    }

    /// Any phase, with or without the context rows. The previews use it.
    fileprivate init(prompt: AIRequestPrompt, flow: AIRequestWatchFlow, isDisplayVerified: Bool) {
        self.prompt = prompt
        _flow = State(initialValue: flow)
        self.isDisplayVerified = isDisplayVerified
        contextRows = AIRequestContextRows.rows(context: prompt.context, shown: prompt.shown, testKind: prompt.testKind)
    }

    private var center: AIRequestWatchCenter { .shared }

    var body: some View {
        Group {
            switch flow.phase {
            case .asking:
                request
            case let .sending(_, since, _):
                // Every second, so the wording turns to "No reply" 15 s after the answer.
                TimelineView(.periodic(from: since, by: 1)) { context in
                    outcome(at: context.date)
                }
            default:
                outcome(at: Date())
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(trioBackgroundColor)
        .background {
            // Expires a request nobody has answered when its time is up.
            TimelineView(.explicit([prompt.expiresAt])) { context in
                Color.clear.onChange(of: context.date, initial: true) {
                    flow.expireIfDue(at: Date())
                }
            }
        }
        .onAppear {
            if flow.phase == .asking {
                center.screenDidOpen(prompt.id)
            }
        }
        .onDisappear {
            declineIfDismissed()
        }
        // Only this request's receipt and result move the screen on, and only through the flow: the center records an
        // answer before it knows the answer left the watch.
        .onChange(of: center.receipts.contains(prompt.id), initial: true) { _, isReceived in
            if isReceived {
                flow.receiptArrived()
            }
        }
        .onChange(of: center.results[prompt.id], initial: true) { _, result in
            if let result {
                flow.resultArrived(result)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                flow.expireIfDue(at: Date())
                isCrownFocused = true
            } else {
                // The wrist dropped, or the wearer left the app: a half-turned crown starts over.
                confirmationProgress = 0
            }
        }
        .onChange(of: closesBySelf, initial: true) { _, closes in
            if closes {
                startClosing()
            }
        }
    }

    // MARK: Asking

    /// How much of the asking screen fits. Each step down sheds one more thing.
    private struct Fit {
        var titleLines = 2
        var showsFatAndProtein = true
        var showsHint = true
        var smallControls = false
        /// The last resort: the context rows take whatever room is left, and their text shrinks to fit it.
        var squeezesContext = false
    }

    private var request: some View {
        // On a small screen it sheds, in order: the title's second line, the fat and protein, the hint, the controls'
        // size, and last the context rows' text size. The title, the amounts and Decline always stay, every context row
        // stays, and an amount is never scaled or cut.
        ViewThatFits(in: .vertical) {
            asking(Fit())
            asking(Fit(titleLines: 1))
            asking(Fit(titleLines: 1, showsFatAndProtein: false))
            asking(Fit(titleLines: 1, showsFatAndProtein: false, showsHint: false))
            asking(Fit(titleLines: 1, showsFatAndProtein: false, showsHint: false, smallControls: true))
            asking(Fit(titleLines: 1, showsFatAndProtein: false, showsHint: false, smallControls: true, squeezesContext: true))
        }
        .focusable(true)
        .focused($isCrownFocused)
        .digitalCrownRotation(
            $confirmationProgress,
            from: 0.0,
            through: 1.0,
            by: 0.05,
            sensitivity: .medium,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onAppear {
            isCrownFocused = true
        }
        .onChange(of: confirmationProgress) { _, newValue in
            if newValue >= 1.0 {
                approve()
            } else if newValue > 0 {
                WKInterfaceDevice.current().play(.click)
            }
        }
    }

    /// The request, in the brief's order: the title, the dose, the carbs, Trio's context, the fat and protein, then the
    /// bar, the hint and the buttons. Everything but the context rows has layout priority, so in the last resort the
    /// rows are the part that gives.
    private func asking(_ fit: Fit) -> some View {
        VStack(spacing: 4) {
            Text(prompt.title)
                .font(.footnote.bold())
                .multilineTextAlignment(.center)
                .lineLimit(fit.titleLines)
                .padding(.top, 6)
                .layoutPriority(1)

            VStack(alignment: .leading, spacing: 2) {
                amountRow("Bolus", value: units, color: Color.insulin)
                    .layoutPriority(1)
                amountRow("Carbs:", value: carbs, color: .orange)
                    .layoutPriority(1)

                contextRowsView(squeezed: fit.squeezesContext)

                if fit.showsFatAndProtein, let fatAndProtein {
                    Text(fatAndProtein)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                }
            }
            .padding(.horizontal)

            ProgressView(value: confirmationProgress, total: 1.0)
                .tint(confirmationProgress > 0 ? Color.loopGreen : Color.gray)
                .padding(.horizontal)
                .layoutPriority(1)

            if fit.showsHint {
                hint
                    .layoutPriority(1)
            }

            HStack {
                Button("Decline") {
                    answer(.decline, declinedBy: .button)
                }
                .buttonStyle(.bordered)

                approveButton
            }
            .controlSize(fit.smallControls ? .small : .regular)
            .layoutPriority(1)
        }
    }

    /// A label and its amount. The amount is never scaled or cut: the label gives way first.
    private func amountRow(_ label: LocalizedStringKey, value: String, color: Color) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .bold()
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
        }
    }

    /// Trio's context, never dropped. It wraps rather than being cut, except in the last resort, where it shrinks to the
    /// room left. Without Trio's signature over it, one row says it couldn't be checked.
    @ViewBuilder private func contextRowsView(squeezed: Bool) -> some View {
        if isDisplayVerified {
            ForEach(Array(contextRows.enumerated()), id: \.offset) { _, row in
                Group {
                    if row.isWarning {
                        Label(row.text, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                    } else {
                        Text(row.text)
                    }
                }
                .font(.footnote)
                .minimumScaleFactor(squeezed ? 0.6 : 1)
                .fixedSize(horizontal: false, vertical: !squeezed)
            }
        } else {
            Text("Couldn't check Trio's details for this request.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .minimumScaleFactor(squeezed ? 0.6 : 1)
                .fixedSize(horizontal: false, vertical: !squeezed)
        }
    }

    /// How to approve, or how long is left once that's under a minute.
    private var hint: some View {
        TimelineView(.periodic(from: flow.shownAt, by: 1)) { context in
            Group {
                if let countdown = flow.countdown(at: context.date) {
                    Text(String(
                        localized: "Expires in \(countdown)",
                        comment: "Watch approval: the time left to answer, as m:ss"
                    ))
                        .foregroundStyle(.orange)
                } else {
                    Text(Self.approveHint)
                }
            }
            .font(.footnote)
            .multilineTextAlignment(.center)
            // A second after the expiry at most, should the expiry's own update come a moment early.
            .onChange(of: context.date) {
                flow.expireIfDue(at: Date())
            }
        }
    }

    private static var approveHint: String {
        if #available(watchOS 11, *) {
            return String(
                localized: "Turn the crown or double tap to approve",
                comment: "Watch approval: how to approve, on watchOS 11 and later"
            )
        }
        return String(localized: "Turn the crown to approve", comment: "Watch approval: how to approve, on watchOS 10")
    }

    /// The double tap presses this button. There's none on watchOS 10, which approves with the crown only.
    @ViewBuilder private var approveButton: some View {
        if #available(watchOS 11, *) {
            Button("Approve") {
                approve()
            }
            .buttonStyle(.bordered)
            .tint(Color.loopGreen)
            .handGestureShortcut(.primaryAction)
        }
    }

    // MARK: Answered, expired or ended

    /// One icon over the flow's headline and detail, then Done or Close as the flow's ending says.
    private func outcome(at now: Date) -> some View {
        let ending = flow.ending(at: now)
        let text = flow.text(at: now, units: prompt.shown.units, source: prompt.source)
        let content = VStack(spacing: 6) {
            icon(appearance(at: now), ring: ending.ring)

            Text(text.headline)
                .font(.headline)
                .multilineTextAlignment(.center)

            if let detail = text.detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            endButton(ending)
                .padding(.top, 4)
        }
        .padding(.horizontal)

        // Centered when it fits, and scrolled with the crown when a long detail doesn't.
        return ViewThatFits(in: .vertical) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            ScrollView { content }
        }
    }

    @ViewBuilder private func icon(_ look: Look, ring: AIRequestWatchRing?) -> some View {
        if let symbol = look.symbol {
            ZStack {
                if let ring {
                    Circle()
                        .trim(from: 0, to: ringLeft)
                        .stroke(Self.color(of: ring), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Image(systemName: symbol)
                    .font(.system(size: 40))
                    .foregroundStyle(look.color)
            }
            .frame(width: 52, height: 52)
        } else {
            ProgressView()
        }
    }

    private static func color(of ring: AIRequestWatchRing) -> Color {
        switch ring {
        case .success:
            return .loopGreen
        case .neutral:
            return .secondary
        }
    }

    @ViewBuilder private func endButton(_ ending: AIRequestWatchEnding) -> some View {
        switch ending {
        case .waits:
            EmptyView()
        case .closesBySelf:
            Button("Done") {
                close()
            }
            .buttonStyle(.bordered)
        case .close:
            Button("Close") {
                close()
            }
            .buttonStyle(.bordered)
        }
    }

    private struct Look {
        /// The SF Symbol, or `nil` for a spinner.
        let symbol: String?
        let color: Color
    }

    /// The phase's icon. Only a success the phone reported is a green check: "Sent to Trio" is a paper plane, as the
    /// answer is on its way and nothing is known yet.
    private func appearance(at now: Date) -> Look {
        let warning = "exclamationmark.triangle.fill"
        switch flow.phase {
        case .asking:
            return Look(symbol: nil, color: .secondary)
        case let .sending(_, _, queued):
            if flow.isNoReply(at: now) {
                return Look(symbol: warning, color: .orange)
            }
            return Look(symbol: queued ? "clock.arrow.circlepath" : nil, color: .secondary)
        case .received(.approve):
            return Look(symbol: "paperplane.circle", color: .secondary)
        case .received(.decline):
            return Look(symbol: "xmark.circle", color: .secondary)
        case .notSent:
            return Look(symbol: warning, color: .loopRed)
        case .expired:
            return Look(symbol: "clock.badge.xmark", color: .secondary)
        case let .result(message):
            switch message.tone {
            case .success:
                return Look(symbol: "checkmark.circle.fill", color: .loopGreen)
            case .neutral:
                return Look(symbol: "xmark.circle", color: .secondary)
            case .warning:
                return Look(symbol: warning, color: .orange)
            case .failure:
                return Look(symbol: warning, color: .loopRed)
            }
        }
    }

    /// Whether the phase closes the screen by itself, as the flow says.
    private var closesBySelf: Bool {
        flow.ending(at: Date()).ring != nil
    }

    /// Drains the ring, then closes the screen, unless the phase has since moved on to one that waits for Close.
    private func startClosing() {
        guard !isClosing else { return }
        isClosing = true
        withAnimation(.linear(duration: 1.5), completionCriteria: .logicallyComplete) {
            ringLeft = 0
        } completion: {
            if closesBySelf {
                close()
            }
        }
    }

    // MARK: Answering

    /// An Approve counts only once the screen has been open for a moment, so a tap or double tap already under way
    /// when the request arrived can't dose.
    private func approve() {
        guard flow.acceptsApprove(at: Date()) else {
            WKInterfaceDevice.current().play(.retry)
            confirmationProgress = 0
            return
        }
        answer(.approve, declinedBy: nil)
    }

    /// Sends the answer, unless the request has expired or has stopped being the one on screen, and shows what became
    /// of sending it.
    private func answer(_ decision: AIRequestDecision, declinedBy: AIRequestDeclinedBy?) {
        guard flow.phase == .asking, center.presented?.id == prompt.id else { return }
        let now = Date()
        guard now < prompt.expiresAt else {
            flow.expireIfDue(at: now)
            return
        }
        if decision == .approve {
            WKInterfaceDevice.current().play(.success)
        }
        let result = center.answer(prompt, decision, declinedBy: declinedBy)
        flow.answered(decision, result, at: now)
    }

    /// Dismisses the screen, if it's still showing this request.
    private func close() {
        center.closeScreen(prompt.id)
    }

    /// The safety net for the hidden X: a screen the system closed while it was still asking counts as a dismissal, as
    /// swiping the notification away does. A screen Trio closed or replaced itself doesn't, and neither does one that's
    /// still presented.
    private func declineIfDismissed() {
        let closedByTrio = center.screenWasClosedByTrio(prompt.id)
        guard flow.phase == .asking, !closedByTrio, center.presented?.id != prompt.id, center.isOpen(prompt) else { return }
        _ = center.answer(prompt, .decline, declinedBy: .dismissed)
    }

    // MARK: Amounts

    /// "2.10 U": the shown dose as it is, with two decimals and a `.`, as in the notification.
    private var units: String {
        String(
            localized: "\(prompt.shown.units)\u{00A0}U",
            comment: "Watch approval: Trio's dose in units. The no-break space keeps the number with its unit."
        )
    }

    /// "35 g", without trailing zeros.
    private var carbs: String {
        String(
            localized: "\(Self.trimmed(prompt.shown.carbs))\u{00A0}g",
            comment: "Watch approval: the carbs in grams. The no-break space keeps the number with its unit."
        )
    }

    /// "10 g fat · 12 g protein", or `nil` when there's neither.
    private var fatAndProtein: String? {
        var parts: [String] = []
        if let fat = Self.positive(prompt.shown.fat) {
            parts.append(String(
                localized: "\(fat)\u{00A0}g fat",
                comment: "Watch approval: the fat in grams. The no-break space keeps the number with its unit."
            ))
        }
        if let protein = Self.positive(prompt.shown.protein) {
            parts.append(String(
                localized: "\(protein)\u{00A0}g protein",
                comment: "Watch approval: the protein in grams. The no-break space keeps the number with its unit."
            ))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The amounts are strings with a `.` separator, whatever the wearer's locale.
    private static func amount(_ shown: String) -> Decimal? {
        Decimal(string: shown, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// The amount without trailing zeros: "35.00" is "35", "12.50" is "12.5".
    private static func trimmed(_ shown: String) -> String {
        amount(shown)?.description ?? shown
    }

    /// The amount without trailing zeros when it's above 0, otherwise `nil`.
    private static func positive(_ shown: String) -> String? {
        guard let value = amount(shown), value > 0 else { return nil }
        return value.description
    }
}

private extension AIRequestWatchEnding {
    /// The ring of a phase that closes by itself, or `nil`.
    var ring: AIRequestWatchRing? {
        if case let .closesBySelf(ring) = self {
            return ring
        }
        return nil
    }
}

extension AIRequestPrompt: Identifiable {}

extension View {
    /// Shows the approval screen over this view while the watch has a request to present.
    func aiRequestApproval() -> some View {
        modifier(AIRequestApprovalPresenter())
    }
}

private struct AIRequestApprovalPresenter: ViewModifier {
    @Bindable private var center = AIRequestWatchCenter.shared

    func body(content: Content) -> some View {
        content.fullScreenCover(item: $center.presented) { prompt in
            // A different request starts the screen over, rather than carrying the crown's progress across.
            AIRequestApprovalView(prompt: prompt).id(prompt.id)
        }
    }
}

// MARK: Previews

private extension AIRequestPrompt {
    static func preview(
        title: String = "ChatGPT: slice of pizza",
        shown: AIRequestShown = AIRequestShown(carbs: "45.00", fat: "0.00", protein: "0.00", units: "2.10"),
        context: AIRequestContext? = AIRequestContext(
            glucose: "142 mg/dL ↗",
            glucoseAgeMinutes: 3,
            recentBolus: AIRequestContext.Recent(amount: "3.00", minutesAgo: 8)
        ),
        testKind: AIRequestTestKind? = nil,
        expiresIn lifetime: TimeInterval = 300
    ) -> AIRequestPrompt {
        AIRequestPrompt(
            id: "preview-request",
            source: "ChatGPT",
            description: "slice of pizza",
            shown: shown,
            title: title,
            body: "",
            expiresAt: Date().addingTimeInterval(lifetime),
            approvalStyle: .twoStep,
            answerRoute: .both,
            answerToken: nil,
            answerURL: nil,
            context: context,
            testKind: testKind
        )
    }
}

private extension AIRequestResultMessage {
    static func preview(headline: String, detail: String, tone: Tone, answeredOn: AIRequestAnswerSide? = .watch)
        -> AIRequestResultMessage
    {
        AIRequestResultMessage(
            id: "preview-request",
            title: "ChatGPT: slice of pizza",
            headline: headline,
            detail: detail,
            tone: tone,
            answeredOn: answeredOn
        )
    }
}

/// The screen for `prompt` in the phase `advance` moves it to, opened a few seconds ago.
private func previewScreen(
    _ prompt: AIRequestPrompt = .preview(),
    isDisplayVerified: Bool = true,
    _ advance: (inout AIRequestWatchFlow) -> Void = { _ in }
) -> AIRequestApprovalView {
    var flow = AIRequestWatchFlow(shownAt: Date().addingTimeInterval(-5), expiresAt: prompt.expiresAt)
    advance(&flow)
    return AIRequestApprovalView(prompt: prompt, flow: flow, isDisplayVerified: isDisplayVerified)
}

#Preview("Asking") {
    previewScreen()
}

#Preview("Asking: every context row, long title, fat and protein") {
    // The worst case for a 41 mm watch: every row Trio can add at once.
    previewScreen(.preview(
        title: "Claude: lasagne with a side salad and garlic bread",
        shown: AIRequestShown(carbs: "82.50", fat: "28.00", protein: "31.25", units: "0.00"),
        context: AIRequestContext(
            glucose: "61 mg/dL ↘",
            glucoseAgeMinutes: 4,
            recentCarbs: AIRequestContext.Recent(amount: "20", minutesAgo: 6),
            recentBolus: AIRequestContext.Recent(amount: "3.00", minutesAgo: 8),
            noDoseReason: "glucose is forecast to go low"
        ),
        testKind: .real
    ))
}

#Preview("Asking: fat, protein and a long title") {
    previewScreen(.preview(
        title: "Claude: lasagne with a side salad and garlic bread",
        shown: AIRequestShown(carbs: "82.50", fat: "28.00", protein: "31.25", units: "4.80"),
        context: AIRequestContext(
            glucose: "138 mg/dL ↑",
            glucoseAgeMinutes: 1,
            recentCarbs: AIRequestContext.Recent(amount: "20", minutesAgo: 6)
        )
    ))
}

#Preview("Asking: 0 U dry run") {
    previewScreen(.preview(
        title: "Trio test: 10 g carbs",
        shown: AIRequestShown(carbs: "10.00", fat: "0.00", protein: "0.00", units: "0.00"),
        context: AIRequestContext(glucose: "52 mg/dL ↓", noDoseReason: "glucose is low (52 mg/dL)"),
        testKind: .dryRun
    ))
}

#Preview("Asking: unchecked") {
    previewScreen(isDisplayVerified: false)
}

#Preview("Asking: expiring") {
    previewScreen(.preview(expiresIn: 45))
}

#Preview("Approving") {
    previewScreen { $0.answered(.approve, .sent, at: Date()) }
}

#Preview("Waiting for iPhone") {
    previewScreen { $0.answered(.approve, .queued, at: Date()) }
}

#Preview("No reply") {
    previewScreen { $0.answered(.approve, .queued, at: Date().addingTimeInterval(-20)) }
}

#Preview("Sent to Trio") {
    previewScreen {
        $0.answered(.approve, .sent, at: Date())
        $0.receiptArrived()
    }
}

#Preview("Bolus started") {
    previewScreen {
        $0.answered(.approve, .sent, at: Date())
        $0.resultArrived(.preview(headline: "Bolus started: 2.10\u{00A0}U", detail: "45\u{00A0}g carbs logged.", tone: .success))
    }
}

#Preview("Replaced after Approve") {
    previewScreen {
        $0.answered(.approve, .sent, at: Date())
        $0.resultArrived(.preview(
            headline: "Replaced",
            detail: "A newer request from ChatGPT is waiting.",
            tone: .neutral,
            answeredOn: nil
        ))
    }
}

#Preview("Carbs logged, no bolus") {
    previewScreen {
        $0.answered(.approve, .sent, at: Date())
        $0.resultArrived(.preview(
            headline: "Carbs logged, no bolus",
            detail: "Trio gave 3.00\u{00A0}U after working out this dose. Ask again in a few minutes. Check Trio before you bolus yourself.",
            tone: .warning
        ))
    }
}

#Preview("Couldn't send") {
    previewScreen { $0.answered(.approve, .notSent, at: Date()) }
}

#Preview("Expired") {
    previewScreen(.preview(expiresIn: -10)) { $0.expireIfDue(at: Date()) }
}
