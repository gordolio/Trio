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
                for point in [CGPoint(x: 0.08, y: 0.72), CGPoint(x: 0.27, y: 0.62),
                              CGPoint(x: 0.73, y: 0.62), CGPoint(x: 0.92, y: 0.72)]
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

struct GlucoseBackfillToast: View {
    @ObservedObject var backfill: NightscoutBackfill

    var body: some View {
        if let feedback = backfill.feedback {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: feedback.isError ? "exclamationmark.circle" : "checkmark.circle")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(feedback.title).font(.footnote.weight(.semibold))
                    Text(feedback.detail).font(.footnote).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                Button(action: backfill.dismissFeedback) {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Dismiss backfill result"))
            }
            .foregroundStyle(.primary)
            .padding(.leading, 16)
            .padding(.trailing, 4)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.secondary.opacity(0.3)))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .accessibilityIdentifier("glucoseBackfillToast")
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
