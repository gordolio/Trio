import SwiftUI
import Swinject

extension SettingsTest {
    /// The hub: every guided test in one place, with when each was last run, and what the latest basal tests
    /// said about each part of the day.
    struct RootView: BaseView {
        let resolver: Resolver

        @State var state = StateModel()
        /// Whether the confirmation to end the old carb ratio test is up.
        @State private var showsEndCarbRatio = false

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        var body: some View {
            List {
                if let session = state.activeSession {
                    Section {
                        activeBanner(for: session)
                    }
                    .listRowBackground(Color.chart)
                }

                Section(
                    header: Text("Check Your Settings"),
                    footer: Text(
                        "Each test shows you which way a setting leans. You decide whether to change it. Work in this order: basal first, then insulin sensitivity, then carb ratio."
                    )
                ) {
                    ForEach(SettingsTestKind.allCases) { kind in
                        row(for: kind)
                    }
                }
                .listRowBackground(Color.chart)

                if !state.basalPeriods.isEmpty {
                    Section(
                        header: Text("Basal time periods"),
                        footer: basalPeriodsFooter
                    ) {
                        ForEach(state.basalPeriods, id: \.entry.startMinutes) { period in
                            periodRow(for: period, kind: .basal)
                        }
                    }
                    .listRowBackground(Color.chart)
                }

                if !state.isfPeriods.isEmpty {
                    Section(
                        header: Text("ISF time periods"),
                        footer: isfPeriodsFooter
                    ) {
                        ForEach(state.isfPeriods, id: \.entry.startMinutes) { period in
                            periodRow(for: period, kind: .isf)
                        }
                    }
                    .listRowBackground(Color.chart)
                }

                if !state.carbRatioPeriods.isEmpty {
                    Section(
                        header: Text("Carb ratio time periods"),
                        footer: carbRatioPeriodsFooter
                    ) {
                        ForEach(state.carbRatioPeriods, id: \.entry.startMinutes) { period in
                            periodRow(for: period, kind: .carbRatio)
                        }
                    }
                    .listRowBackground(Color.chart)
                }
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle("Settings Tests")
            .navigationBarTitleDisplayMode(.automatic)
            .onAppear {
                let isFirstAppear = state.isInitial
                configureView()
                // A test archives its result after the running session has ended, so the list can be a step
                // behind when this screen comes back into view. A carb ratio test may have finished meanwhile too.
                if !isFirstAppear {
                    state.refreshHistory()
                    state.refreshCarbRatio()
                }
            }
            .confirmationDialog("End the carb ratio test?", isPresented: $showsEndCarbRatio, titleVisibility: .visible) {
                Button("End Test", role: .destructive) { Task { await state.endCarbRatioTest() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "This test is from the old carb ratio wizard and can't be finished. End Test turns off its Calibration Mode override and clears the test. Its result isn't kept."
                )
            }
        }

        // MARK: - Rows

        @ViewBuilder private func row(for kind: SettingsTestKind) -> some View {
            if kind == .carbRatio, state.carbRatioInProgress {
                carbRatioInProgressRow
            } else if let screen = state.screen(for: kind) {
                rowContent(for: kind, locked: false).navigationLink(to: screen, from: self)
            } else {
                rowContent(for: kind, locked: true)
            }
        }

        /// A row that can't be opened (a test being rebuilt) dims its icon and title, and keeps its status line at full
        /// strength, because that line says why. A row whose test can't start while another runs still opens, undimmed.
        private func rowContent(for kind: SettingsTestKind, locked: Bool) -> some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: kind.icon)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                    .opacity(locked ? 0.55 : 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.title)
                        .font(.body.weight(.medium))
                        .opacity(locked ? 0.55 : 1)
                    Text(kind.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(lastTestedText(for: kind))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    // A warning only: the row still opens the test. The Check screens' orange triangle, so it isn't missed
                    // among the row's grey lines.
                    if !locked, let note = gateNote(for: kind) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Image(systemName: SettingsTestCheckState.warning.icon)
                                .foregroundStyle(SettingsTestCheckState.warning.color)
                                .accessibilityLabel(Text("Warning"))
                            Text(note)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.caption)
                    }
                }
            }
            .padding(.vertical, 4)
        }

        /// The warning under a row: the sensitivity row's from the newest basal test, the carb ratio row's from the newest
        /// ISF test. Not under the old carb ratio test's row, which offers to end that test.
        private func gateNote(for kind: SettingsTestKind) -> String? {
            switch kind {
            case .isf: return state.isfGateNote
            case .carbRatio: return state.carbRatioInProgress ? nil : state.carbRatioGateNote
            case .basal: return nil
            }
        }

        /// The old carb ratio wizard left a test under way. The row never opens the wizard, which is being retired; it
        /// offers to end the test, which turns the test's SMB-off override off. Shown whatever else is running, because
        /// ending it only puts things back.
        private var carbRatioInProgressRow: some View {
            VStack(alignment: .leading, spacing: 8) {
                rowContent(for: .carbRatio, locked: false)
                // In line with the row's text, past the icon.
                Group {
                    Button("End This Test", role: .destructive) { showsEndCarbRatio = true }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.borderless)
                    if let error = state.carbRatioEndError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 40)
            }
            .padding(.bottom, 4)
        }

        private func lastTestedText(for kind: SettingsTestKind) -> String {
            // The old wizard's test, which its row offers to end.
            if kind == .carbRatio, state.carbRatioInProgress {
                return String(localized: "A carb ratio test from before is still running.")
            }
            switch kind.availability {
            case .comingSoon: return String(localized: "Coming soon")
            case .beingRebuilt:
                return kind == .carbRatio && state.carbRatioInProgress
                    ? String(localized: "A carb ratio test from before is still running.")
                    : String(localized: "Being rebuilt")
            case .available: break
            }
            if state.isLocked(kind), let running = state.activeSession?.kind {
                return String(localized: "Finish the \(running.title) test first")
            }
            guard let record = state.lastRecords[kind] else { return String(localized: "Not tested yet") }
            let when = record.completedAt.formatted(.relative(presentation: .named))
            return String(localized: "Last tested \(when)")
        }

        // MARK: - Basal time periods

        /// Two lines of the docs, word for word, and what the blue rates are.
        private var basalPeriodsFooter: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "\(BasalTest.Docs.testTimesOfDaySeparately) \(BasalTest.Docs.waitBetweenAdjustments).")
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "gearshape")
                        .accessibilityHidden(true)
                    Text("Blue values come from your settings")
                }
            }
        }

        // MARK: - ISF time periods

        /// Two lines of the docs, word for word, and what the blue values are.
        private var isfPeriodsFooter: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "\(ISFTest.Docs.testSystematically). \(ISFTest.Docs.waitBetweenChanges).")
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "gearshape")
                        .accessibilityHidden(true)
                    Text("Blue values come from your settings")
                }
            }
        }

        // MARK: - Carb ratio time periods

        /// Two lines of the docs, word for word, and what the blue ratios are.
        private var carbRatioPeriodsFooter: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "\(CarbRatioTest.Docs.oneMealAtATime). \(CarbRatioTest.Docs.waitBetweenChanges).")
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "gearshape")
                        .accessibilityHidden(true)
                    Text("Blue values come from your settings")
                }
            }
        }

        private func periodRow(for period: SettingsTestPeriod, kind: SettingsTestKind) -> some View {
            let span = SettingsTestSchedule.spanText(of: period.entry)
            let value: String
            switch kind {
            case .isf: value = state.formatISF(period.entry.value)
            case .carbRatio: value = state.formatCarbRatio(period.entry.value)
            case .basal: value = "\(period.entry.value.formatted(.number.precision(.fractionLength(2)))) U/h"
            }
            return VStack(alignment: .leading, spacing: 3) {
                // The value is the user's own setting, so it is blue.
                (Text(verbatim: "\(span) · ") + Text(verbatim: value).foregroundStyle(Color.accentColor))
                    .font(.body.weight(.medium))
                Text(kind.periodStatusText(for: period))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }

        private func activeBanner(for session: SettingsTestSession) -> some View {
            HStack(spacing: 12) {
                Image(systemName: "timer")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(session.kind.title) test in progress")
                        .font(.subheadline.weight(.semibold))
                    Text("Open it below to follow along or stop it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
