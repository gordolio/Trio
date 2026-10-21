import Foundation
import SwiftUI
import WatchKit

/// The screen an AI assistant's request opens on the watch: what it asks for, the wearer's answer, and what became of
/// it. The wearer approves by turning the crown, or on watchOS 11 and later with Approve or a double tap, and declines
/// with the button. The screen has no X. Once it's answered, it closes itself after a good or neutral result, and
/// otherwise waits for Close. If the system still closes it while it's asking, that counts as a dismissal.
///
/// The carbs and dose come from `prompt.shown`, which is what the answer is signed against and what the phone checks
/// it for. The context rows are Trio's own, and show only when Trio's signature over them checks out.
///
/// `AIRequestWatchFlow` holds the phases. The phone's receipt and result move it on, and the clock only expires a
/// request nobody has answered. Nothing sleeps: `TimelineView`s tell the time, and the closing ring is an animation
/// whose completion closes the screen.
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
    private let contextLines: [ContextLine]

    private let trioBackgroundColor = LinearGradient(
        gradient: Gradient(colors: [Color.bgDarkBlue, Color.bgDarkerDarkBlue]),
        startPoint: .top,
        endPoint: .bottom
    )

    /// A reading is shown with its age from this many minutes old, as in the notification.
    private static let glucoseAgeShownFrom = 2
    /// The hint becomes a countdown with less than this many seconds left.
    private static let countdownFrom = 60

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
        contextLines = Self.contextLines(for: prompt)
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

    private var request: some View {
        VStack(spacing: 4) {
            // On a small screen the title's second line goes first, then the fat and protein. The amounts, Trio's
            // context rows, the bar, the hint and the buttons always stay.
            ViewThatFits(in: .vertical) {
                summary(titleLines: 2, showsFatAndProtein: true)
                summary(titleLines: 1, showsFatAndProtein: true)
                summary(titleLines: 1, showsFatAndProtein: false)
            }

            ProgressView(value: confirmationProgress, total: 1.0)
                .tint(confirmationProgress > 0 ? Color.loopGreen : Color.gray)
                .padding(.horizontal)

            hint

            HStack {
                Button("Decline") {
                    answer(.decline, declinedBy: .button)
                }
                .buttonStyle(.bordered)

                approveButton
            }
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

    /// What the request asks for: the dose and the carbs first, then Trio's context.
    private func summary(titleLines: Int, showsFatAndProtein: Bool) -> some View {
        VStack(spacing: 2) {
            Text(prompt.title)
                .font(.footnote.bold())
                .multilineTextAlignment(.center)
                .lineLimit(titleLines)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                amountRow("Bolus", value: units, color: Color.insulin)
                amountRow("Carbs:", value: carbs, color: .orange)

                if showsFatAndProtein, let fatAndProtein {
                    Text(fatAndProtein)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                contextRows
            }
            .padding(.horizontal)
        }
    }

    private func amountRow(_ label: LocalizedStringKey, value: String, color: Color) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .bold()
                .foregroundStyle(color)
        }
    }

    /// Trio's context, never cut short. Without Trio's signature over it, one row says it couldn't be checked.
    @ViewBuilder private var contextRows: some View {
        if isDisplayVerified {
            ForEach(Array(contextLines.enumerated()), id: \.offset) { _, line in
                Group {
                    if line.isWarning {
                        Label(line.text, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                    } else {
                        Text(line.text)
                    }
                }
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("Couldn't check Trio's details for this request.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// How to approve, or how long is left once that's under a minute.
    private var hint: some View {
        TimelineView(.periodic(from: flow.shownAt, by: 1)) { context in
            let secondsLeft = max(0, Int(prompt.expiresAt.timeIntervalSince(context.date).rounded(.up)))
            Group {
                if secondsLeft < Self.countdownFrom {
                    Text(String(
                        localized: "Expires in \(Self.countdown(secondsLeft))",
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

    /// "0:45".
    private static func countdown(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
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

    /// One icon over the flow's headline and detail, then Done or Close when the phase has one.
    private func outcome(at now: Date) -> some View {
        let look = appearance(at: now)
        let text = flow.text(at: now, units: prompt.shown.units, source: prompt.source)
        let content = VStack(spacing: 6) {
            icon(look)

            Text(text.headline)
                .font(.headline)
                .multilineTextAlignment(.center)

            if let detail = text.detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            endButton(look.ending)
                .padding(.top, 4)
        }
        .padding(.horizontal)

        // Centered when it fits, and scrolled with the crown when a long detail doesn't.
        return ViewThatFits(in: .vertical) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            ScrollView { content }
        }
    }

    @ViewBuilder private func icon(_ look: Look) -> some View {
        if let symbol = look.symbol {
            ZStack {
                if look.ending == .done {
                    Circle()
                        .trim(from: 0, to: ringLeft)
                        .stroke(look.color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
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

    @ViewBuilder private func endButton(_ ending: Ending) -> some View {
        switch ending {
        case .waits:
            EmptyView()
        case .done:
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

    /// How a phase ends: on its own, with Done and the ring, or with Close.
    private enum Ending {
        /// No button: the phone's receipt or result moves it on.
        case waits
        /// Closes itself when the ring runs out, or with Done.
        case done
        /// Stays until the wearer closes it.
        case close
    }

    private struct Look {
        /// The SF Symbol, or `nil` for a spinner.
        let symbol: String?
        let color: Color
        let ending: Ending
    }

    private func appearance(at now: Date) -> Look {
        let warning = "exclamationmark.triangle.fill"
        switch flow.phase {
        case .asking:
            return Look(symbol: nil, color: .secondary, ending: .waits)
        case let .sending(_, _, queued):
            if flow.isNoReply(at: now) {
                return Look(symbol: warning, color: .orange, ending: .close)
            }
            return Look(symbol: queued ? "clock.arrow.circlepath" : nil, color: .secondary, ending: .waits)
        case .received(.approve):
            return Look(symbol: "checkmark.circle.fill", color: .loopGreen, ending: .waits)
        case .received(.decline):
            return Look(symbol: "xmark.circle", color: .secondary, ending: .done)
        case .notSent:
            return Look(symbol: warning, color: .loopRed, ending: .close)
        case .expired:
            return Look(symbol: "clock.badge.xmark", color: .secondary, ending: .close)
        case let .result(message):
            switch message.tone {
            case .success:
                return Look(symbol: "checkmark.circle.fill", color: .loopGreen, ending: .done)
            case .neutral:
                return Look(symbol: "xmark.circle", color: .secondary, ending: .done)
            case .warning:
                return Look(symbol: warning, color: .orange, ending: .close)
            case .failure:
                return Look(symbol: warning, color: .loopRed, ending: .close)
            }
        }
    }

    /// Whether the phase closes the screen by itself: a success, a neutral result or a decline the phone has.
    private var closesBySelf: Bool {
        appearance(at: Date()).ending == .done
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

    // MARK: Amounts and context

    /// A row of Trio's context. A warning is about insulin or carbs given a moment ago, or a test that gives the real
    /// dose.
    private struct ContextLine {
        let text: String
        let isWarning: Bool
    }

    /// Trio's context rows, in order: carbs and insulin given a moment ago, the glucose, why the dose is 0 U, and what
    /// a test does. No context and an empty one show the same.
    private static func contextLines(for prompt: AIRequestPrompt) -> [ContextLine] {
        let context = prompt.context ?? AIRequestContext()
        var lines: [ContextLine] = []

        if let carbs = context.recentCarbs {
            lines.append(ContextLine(
                text: String(
                    localized: "Carbs \(carbs.amount)\u{00A0}g logged \(String(carbs.minutesAgo)) min ago",
                    comment: "Watch approval: carbs logged a few minutes ago. The no-break space keeps the number with its unit."
                ),
                isWarning: true
            ))
        }
        if let bolus = context.recentBolus {
            lines.append(ContextLine(
                text: String(
                    localized: "Bolus \(bolus.amount)\u{00A0}U given \(String(bolus.minutesAgo)) min ago",
                    comment: "Watch approval: a bolus given a few minutes ago. The no-break space keeps the number with its unit."
                ),
                isWarning: true
            ))
        }
        if let glucose = context.glucose, !glucose.isEmpty {
            var parts = [glucose]
            if let age = context.glucoseAgeMinutes, age >= glucoseAgeShownFrom {
                parts.append(String(
                    localized: "\(String(age)) min ago",
                    comment: "Watch approval: how old the glucose reading is, in minutes"
                ))
            }
            lines.append(ContextLine(text: parts.joined(separator: " · "), isWarning: false))
        }
        if let reason = context.noDoseReason, !reason.isEmpty {
            lines.append(ContextLine(
                text: String(
                    localized: "Trio suggests no insulin now: \(reason)",
                    comment: "Watch approval: why Trio's dose is 0 U. The placeholder is the reason, for example 'glucose is low (52 mg/dL)'."
                ),
                isWarning: false
            ))
        } else if givesNoBolus(prompt.shown) {
            // Trio only says a reason it knows is true.
            lines.append(ContextLine(
                text: String(
                    localized: "Trio suggests no insulin now",
                    comment: "Watch approval: Trio's dose is 0 U and there's no reason to give"
                ),
                isWarning: false
            ))
        }
        switch prompt.testKind {
        case .dryRun:
            lines.append(ContextLine(
                text: String(localized: "Test only: nothing is given", comment: "Watch approval: this request is a dry-run test"),
                isWarning: false
            ))
        case .real:
            lines.append(ContextLine(
                text: String(
                    localized: "Real dose. Decline unless you're eating this.",
                    comment: "Watch approval: this request is a test that gives Trio's real dose"
                ),
                isWarning: true
            ))
        case nil:
            break
        }
        return lines
    }

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

    private static func givesNoBolus(_ shown: AIRequestShown) -> Bool {
        (amount(shown.units) ?? 1) <= 0
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
    static func preview(headline: String, detail: String, tone: Tone) -> AIRequestResultMessage {
        AIRequestResultMessage(
            id: "preview-request",
            title: "ChatGPT: slice of pizza",
            headline: headline,
            detail: detail,
            tone: tone,
            answeredOn: .watch
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
