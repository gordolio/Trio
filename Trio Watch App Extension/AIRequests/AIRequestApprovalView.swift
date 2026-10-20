import Foundation
import SwiftUI
import WatchKit

/// The screen an AI assistant's request opens on the watch: what it asks for, and the wearer's answer. The
/// wearer approves by turning the crown or with a double tap, or declines with the button.
///
/// The carbs and dose come from `prompt.shown`, which is what the answer is signed against and what the
/// phone checks it for. `prompt.body` is the service's own text, so it's only context below them.
struct AIRequestApprovalView: View {
    let prompt: AIRequestPrompt

    @State private var confirmationProgress = 0.0
    @State private var hasAnswered = false
    @State private var hasExpired: Bool
    @FocusState private var isCrownFocused: Bool

    private let trioBackgroundColor = LinearGradient(
        gradient: Gradient(colors: [Color.bgDarkBlue, Color.bgDarkerDarkBlue]),
        startPoint: .top,
        endPoint: .bottom
    )

    init(prompt: AIRequestPrompt) {
        self.prompt = prompt
        _hasExpired = State(initialValue: Date() >= prompt.expiresAt)
    }

    var body: some View {
        Group {
            if hasAnswered {
                sentToPhone
            } else if hasExpired {
                expired
            } else {
                request
            }
        }
        .background(trioBackgroundColor)
        .task {
            await expireWhenDue()
        }
    }

    private var request: some View {
        VStack(spacing: 4) {
            // On a small screen the context goes first, then the second line of the title, so the amounts, the
            // crown hint and the buttons always fit.
            ViewThatFits(in: .vertical) {
                summary(showsBody: true, titleLines: 2)
                summary(showsBody: false, titleLines: 2)
                summary(showsBody: false, titleLines: 1)
            }

            ProgressView(value: confirmationProgress, total: 1.0)
                .tint(confirmationProgress >= 1.0 ? .loopGreen : .gray)
                .padding(.horizontal)

            Text("To confirm, dial crown.").font(.footnote)

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
                WKInterfaceDevice.current().play(.success)
                answer(.approve, declinedBy: nil)
            } else if newValue > 0 {
                WKInterfaceDevice.current().play(.click)
            }
        }
    }

    /// What the request asks for. The carbs and dose are the large figures; the service's text goes last, as context.
    private func summary(showsBody: Bool, titleLines: Int) -> some View {
        VStack(spacing: 2) {
            Text(prompt.title)
                .font(.footnote.bold())
                .multilineTextAlignment(.center)
                .lineLimit(titleLines)
                .padding(.top, 6)

            VStack(spacing: 2) {
                HStack {
                    Text("Carbs:")
                    Spacer()
                    Text(grams(prompt.shown.carbs))
                        .bold()
                        .foregroundStyle(.orange)
                }

                HStack {
                    Text("Bolus")
                    Spacer()
                    Text(units(prompt.shown.units))
                        .bold()
                        .foregroundStyle(Color.insulin)
                }

                if hasFat || hasProtein {
                    HStack {
                        if hasFat {
                            Text("Fat \(grams(prompt.shown.fat))")
                        }
                        Spacer()
                        if hasProtein {
                            Text("Protein \(grams(prompt.shown.protein))")
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
            }
            .padding(.horizontal)

            if showsBody {
                Text(prompt.body)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
    }

    /// The double tap gesture presses this button. It's the only primary action on the screen.
    @ViewBuilder private var approveButton: some View {
        let button = Button("Approve") {
            answer(.approve, declinedBy: nil)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.loopGreen)

        if #available(watchOS 11, *) {
            button.handGestureShortcut(.primaryAction)
        } else {
            button
        }
    }

    private var sentToPhone: some View {
        VStack {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(Color.loopGreen)
                .padding()
            Text("Sent to iPhone").multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await closeAfterAcknowledgement()
        }
    }

    private var expired: some View {
        VStack {
            Image(systemName: "clock.badge.xmark")
                .foregroundStyle(Color.secondary)
                .padding()
            Text("This request expired").multilineTextAlignment(.center)

            Button("Close") {
                close()
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Answering

    /// Sends the answer, unless the request has expired or has stopped being the one on screen, and shows that it was sent.
    private func answer(_ decision: AIRequestDecision, declinedBy: AIRequestDeclinedBy?) {
        guard !hasAnswered, AIRequestWatchCenter.shared.presented?.id == prompt.id else { return }
        guard Date() < prompt.expiresAt else {
            hasExpired = true
            return
        }
        hasAnswered = true
        AIRequestWatchCenter.shared.answer(prompt, decision, declinedBy: declinedBy)
    }

    /// Dismisses the screen, if it's still showing this request.
    private func close() {
        let center = AIRequestWatchCenter.shared
        if center.presented?.id == prompt.id {
            center.presented = nil
        }
    }

    private func closeAfterAcknowledgement() async {
        guard (try? await Task.sleep(for: .seconds(2))) != nil else { return }
        close()
    }

    private func expireWhenDue() async {
        let remaining = prompt.expiresAt.timeIntervalSinceNow
        if remaining > 0 {
            guard (try? await Task.sleep(for: .seconds(remaining))) != nil else { return }
        }
        hasExpired = true
    }

    // MARK: Amounts

    private var hasFat: Bool {
        amount(prompt.shown.fat).map { $0 > 0 } ?? false
    }

    private var hasProtein: Bool {
        amount(prompt.shown.protein).map { $0 > 0 } ?? false
    }

    /// The amounts are strings with a `.` separator, whatever the wearer's locale.
    private func amount(_ shown: String) -> Decimal? {
        Decimal(string: shown, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Grams as the wearer's locale writes them, without trailing zeros.
    private func grams(_ shown: String) -> String {
        guard let value = amount(shown) else { return "\(shown) g" }
        return "\(value.formatted(.number.precision(.fractionLength(0 ... 2)))) g"
    }

    private func units(_ shown: String) -> String {
        let unit = String(localized: "U", comment: "Insulin unit")
        guard let value = amount(shown) else { return "\(shown) \(unit)" }
        return "\(value.formatted(.number.precision(.fractionLength(2)))) \(unit)"
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

private extension AIRequestPrompt {
    static func preview(
        title: String = "ChatGPT: slice of pizza",
        body: String = "45 g carbs, 1.35 U. Glucose 112 mg/dL, steady.",
        shown: AIRequestShown = AIRequestShown(carbs: "45.00", fat: "0.00", protein: "0.00", units: "1.35"),
        expiresIn lifetime: TimeInterval = 300
    ) -> AIRequestPrompt {
        AIRequestPrompt(
            id: "preview-request",
            source: "ChatGPT",
            description: "slice of pizza",
            shown: shown,
            title: title,
            body: body,
            expiresAt: Date().addingTimeInterval(lifetime),
            approvalStyle: .twoStep,
            answerRoute: .both,
            answerToken: nil,
            answerURL: nil
        )
    }
}

#Preview("Carbs and dose") {
    AIRequestApprovalView(prompt: .preview())
}

#Preview("Fat, protein and a long body") {
    AIRequestApprovalView(
        prompt: .preview(
            title: "Claude: lasagne with a side salad and garlic bread",
            body: "Lasagne, side salad and garlic bread. 82.5 g carbs, 28 g fat, 31.25 g protein, 4.80 U. Glucose 138 mg/dL, rising.",
            shown: AIRequestShown(carbs: "82.50", fat: "28.00", protein: "31.25", units: "4.80")
        )
    )
}

#Preview("Expired") {
    AIRequestApprovalView(prompt: .preview(expiresIn: -10))
}
