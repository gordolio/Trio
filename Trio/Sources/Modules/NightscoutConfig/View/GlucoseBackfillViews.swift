import SwiftUI
import Swinject

extension Home.RootView {
    var backfillMealPanel: some View {
        let backfill = resolver.resolve(NightscoutBackfill.self)!
        return HStack(spacing: 8) {
            backfillInsulinOnBoard.lineLimit(1).minimumScaleFactor(0.5)
            Spacer(minLength: 0)
            backfillCarbsOnBoard.lineLimit(1).minimumScaleFactor(0.5)
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                GlucoseBackfillButton(
                    backfill: backfill,
                    hasMissingReadings: GlucoseBackfillGaps.hasMissingReadings(
                        dates: state.glucoseFromPersistence.filter { !$0.isManual }.compactMap(\.date),
                        now: state.timerDate
                    )
                )
                alarmsPill
                    .dynamicTypeSize(...DynamicTypeSize.large)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .fixedSize()
        }
        .padding(.horizontal)
        .allowsHitTesting(!isChartReadoutVisible)
        .accessibilityHidden(isChartReadoutVisible)
        .onChange(of: state.timerDate) { backfill.refreshConfiguration() }
    }

    private var backfillCarbsOnBoard: some View {
        let value = (Formatter.decimalFormatterWithTwoFractionDigits.string(
            from: NSNumber(value: state.enactedAndNonEnactedDeterminations.first?.cob ?? 0)
        ) ?? "0") + String(localized: " g", comment: "gram of carbs")
        return HStack(spacing: 5) {
            Image(systemName: "fork.knife").foregroundStyle(Color.loopYellow)
            Text(value).fontWeight(.bold).fontDesign(.rounded)
        }
        .font(.callout)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Carbs on board"))
        .accessibilityValue(Text(value))
    }

    private var backfillInsulinOnBoard: some View {
        let value = (Formatter.decimalFormatterWithTwoFractionDigits.string(from: state.currentIOB as NSNumber) ?? "0") +
            String(localized: " U", comment: "Insulin unit")
        return HStack(spacing: 5) {
            Image(systemName: "syringe.fill").foregroundStyle(Color.insulin)
            Text(value).fontWeight(.bold).fontDesign(.rounded)
        }
        .font(.callout)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Insulin on board"))
        .accessibilityValue(Text(value))
    }
}

extension NightscoutConfig.RootView {
    var backfillSettingsButton: some View {
        let backfill = resolver.resolve(NightscoutBackfill.self)!
        return NightscoutBackfillSettingsButton(backfill: backfill, isConnecting: state.connecting)
            .onChange(of: state.isConnectedToNS) { backfill.refreshConfiguration() }
    }
}

extension View {
    func nightscoutBackfillFeedback(resolver: Resolver) -> some View {
        overlay(alignment: .bottom) {
            GlucoseBackfillToast(backfill: resolver.resolve(NightscoutBackfill.self)!)
                .padding(.bottom, 8)
        }
    }

    /// Floats the result card just above this view's top edge (the Home bottom
    /// panels), over the chart's foot, so it never reflows the fixed zones.
    func nightscoutBackfillFeedbackAbove(resolver: Resolver) -> some View {
        overlay(alignment: .top) {
            GlucoseBackfillToast(backfill: resolver.resolve(NightscoutBackfill.self)!)
                .alignmentGuide(.top) { $0[.bottom] }
        }
    }
}

struct GlucoseBackfillButton: View {
    @ObservedObject var backfill: NightscoutBackfill
    var hasMissingReadings: Bool
    @State var showConfirmation = false

    var body: some View {
        Group {
            if backfill.isConfigured && (hasMissingReadings || backfill.isRunning) {
                Button {
                    showConfirmation = true
                } label: {
                    Group {
                        if backfill.isRunning {
                            ProgressView().controlSize(.small)
                        } else {
                            GlucoseBackfillIcon().frame(width: 23, height: 23)
                        }
                    }
                    .foregroundStyle(.tint)
                    .frame(width: 32, height: 32)
                    .overlay(Circle().stroke(.tint, lineWidth: 2))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(backfill.isRunning)
                .accessibilityLabel(Text("Backfill glucose from Nightscout"))
                .accessibilityHint(Text("Checks Nightscout for missing glucose readings after confirmation."))
                .accessibilityValue(backfill.isRunning ? Text("Backfilling") : Text("Missing readings"))
                .accessibilityIdentifier("glucoseBackfillButton")
                .alert("Backfill from Nightscout?", isPresented: $showConfirmation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Backfill") { Task { await backfill.run() } }
                } message: {
                    Text("Check Nightscout for missing glucose readings from the last 24 hours and add any available records.")
                }
            }
        }
        .onAppear { backfill.refreshConfiguration() }
    }
}

struct GlucoseBackfillIcon: View {
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            Path { path in
                path.move(to: CGPoint(x: width * 0.08, y: height * 0.72))
                path.addLine(to: CGPoint(x: width * 0.27, y: height * 0.62))
                path.move(to: CGPoint(x: width * 0.73, y: height * 0.62))
                path.addLine(to: CGPoint(x: width * 0.92, y: height * 0.72))
                path.move(to: CGPoint(x: width * 0.5, y: height * 0.12))
                path.addLine(to: CGPoint(x: width * 0.5, y: height * 0.61))
                path.move(to: CGPoint(x: width * 0.36, y: height * 0.45))
                path.addLine(to: CGPoint(x: width * 0.5, y: height * 0.61))
                path.addLine(to: CGPoint(x: width * 0.64, y: height * 0.45))
            }
            .stroke(style: StrokeStyle(lineWidth: width * 0.075, lineCap: .round, lineJoin: .round))

            Path { path in
                for point in [
                    CGPoint(x: 0.08, y: 0.72),
                    CGPoint(x: 0.27, y: 0.62),
                    CGPoint(x: 0.73, y: 0.62),
                    CGPoint(x: 0.92, y: 0.72)
                ]
                {
                    path.addEllipse(in: CGRect(
                        x: width * (point.x - 0.065), y: height * (point.y - 0.065),
                        width: width * 0.13, height: height * 0.13
                    ))
                }
                path.addRoundedRect(
                    in: CGRect(x: width * 0.45, y: height * 0.77, width: width * 0.1, height: height * 0.055),
                    cornerSize: CGSize(width: 1, height: 1)
                )
            }
            .fill()
        }
        .accessibilityHidden(true)
    }
}

/// Hosts the backfill result card and owns its enter/exit transitions; stays in the
/// hierarchy while empty so the card's removal can animate.
struct GlucoseBackfillToast: View {
    @ObservedObject var backfill: NightscoutBackfill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let feedback = backfill.feedback {
                GlucoseBackfillToastCard(feedback: feedback, onDismiss: backfill.dismissFeedback)
                    .id(feedback.id)
                    .transition(transition)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: backfill.feedback?.id)
    }

    /// rises in from just below, then fades up and away
    private var transition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 16)),
            removal: .opacity.combined(with: .offset(y: -24)).combined(with: .scale(scale: 0.96, anchor: .bottom))
        )
    }
}

/// Result card styled like the Home panel banners. Successful results count down
/// and dismiss themselves; touching the card refills the countdown.
struct GlucoseBackfillToastCard: View {
    static let countdownDuration: TimeInterval = 3

    let feedback: NightscoutBackfill.Feedback
    let onDismiss: () -> Void

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var countdownRun = 0
    @State private var isHeld = false

    private var tint: Color { feedback.isError ? .orange : .tabBar }

    /// errors stay until dismissed; VoiceOver users dismiss on their own time
    private var autoDismisses: Bool { !feedback.isError && !voiceOverEnabled }

    var body: some View {
        HStack(spacing: 12) {
            icon

            VStack(alignment: .leading, spacing: 1) {
                Text(feedback.title)
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundStyle(.primary)
                Text(feedback.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss backfill result"))
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 8)
        .frame(minHeight: HomeLayout.statsBannerHeight)
        .glassPanel(tint: tint, tintOpacity: 0.18, strokeOpacity: 0.6, strokeWidth: 1)
        .overlay(alignment: .bottom) {
            if autoDismisses {
                GlucoseBackfillCountdownBar(
                    duration: Self.countdownDuration,
                    isRunning: !isHeld,
                    tint: tint,
                    onFinish: { [countdownRun] in
                        guard countdownRun == self.countdownRun, !isHeld else { return }
                        onDismiss()
                    }
                )
                // a fresh bar per run: no in-flight animation to fight when refilling
                .id(countdownRun)
                .padding(.horizontal, 18)
                .padding(.bottom, 1)
            }
        }
        .scaleEffect(isHeld ? 0.98 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHeld)
        .contentShape(GlassChrome.panelShape)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard autoDismisses, !isHeld else { return }
                    isHeld = true
                    countdownRun += 1
                }
                .onEnded { _ in isHeld = false }
        )
        .padding(.horizontal, 10)
        .accessibilityAction(named: Text("Dismiss"), onDismiss)
        .accessibilityIdentifier("glucoseBackfillToast")
    }

    private var icon: some View {
        Group {
            if feedback.isError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold))
            } else {
                // same glyph as the Home button that started the backfill
                GlucoseBackfillIcon().frame(width: 18, height: 18)
            }
        }
        .foregroundStyle(tint)
        .frame(width: 30, height: 30)
        .background(Circle().fill(tint.opacity(0.18)))
        .accessibilityHidden(true)
    }
}

/// Drains from full to empty over `duration`, holding full while not running.
struct GlucoseBackfillCountdownBar: View {
    let duration: TimeInterval
    let isRunning: Bool
    let tint: Color
    let onFinish: () -> Void

    @State private var fraction: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(tint.opacity(0.85))
                .frame(width: geometry.size.width * fraction, height: 4)
        }
        .frame(height: 4)
        .accessibilityHidden(true)
        .onAppear { if isRunning { drain() } }
        .onChange(of: isRunning) { if isRunning { drain() } }
    }

    private func drain() {
        withAnimation(.linear(duration: duration)) {
            fraction = 0
        } completion: {
            onFinish()
        }
    }
}

struct NightscoutBackfillSettingsButton: View {
    @ObservedObject var backfill: NightscoutBackfill
    var isConnecting: Bool

    var body: some View {
        Button {
            Task { await backfill.run() }
        } label: {
            HStack {
                if backfill.isRunning {
                    ProgressView()
                }
                Text(backfill.isRunning ? "Backfilling…" : "Backfill Glucose")
                    .font(.title3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .buttonStyle(.bordered)
        .disabled(!backfill.isConfigured || isConnecting || backfill.isRunning)
        .onAppear { backfill.refreshConfiguration() }
    }
}
