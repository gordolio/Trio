import SwiftUI

extension ISFTest {
    /// A spinner and the line saying what the step waits for, as the Raise and Dose steps show it, e.g. "Waiting for a
    /// recent CGM reading".
    struct WaitingRow: View {
        let text: String

        /// Until the CGM has a reading recent enough to work the tablets or the dose out from.
        static var recentReading: WaitingRow {
            WaitingRow(text: String(localized: "Waiting for a recent CGM reading"))
        }

        var body: some View {
            HStack(spacing: 10) {
                ProgressView()
                Text(text)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Glucose leveling off before the dose: the newest reading with the CGM's arrow, a line saying what the dose waits
    /// for, and the last readings. The Raise step shows it after the tablets, the Dose step while the arrow moves.
    struct LevelingCard: View {
        let state: StateModel
        /// What the step waits for (`ISFTestEvaluator.levelingTitle`).
        let title: String
        /// What the readings mean for the dose, shown once there is a recent reading. Nil when the title says it all.
        let status: String?

        var body: some View {
            SettingsTestCard(title: title) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(state.currentGlucose.map(state.formatWithUnits) ?? "--")
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    if let arrow = state.trendArrow {
                        Text(verbatim: arrow)
                            .font(.title2)
                            .accessibilityLabel(Text("Trend \(arrow)"))
                    }
                    Spacer(minLength: 0)
                }

                if state.doseGlucose == nil {
                    WaitingRow.recentReading
                } else if let status {
                    Text(status)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !state.recentReadings.isEmpty {
                    Divider()
                    readings(Array(state.recentReadings.prefix(4)))
                }
            }
        }

        /// Each reading's time at the leading edge and its glucose at the trailing edge. When the widest row doesn't fit
        /// that way at this text size, every row stacks its time over its glucose instead, so the rows stay aligned. A
        /// glucose keeps its unit on one line.
        private func readings(_ readings: [BasalTestReading]) -> some View {
            ViewThatFits(in: .horizontal) {
                VStack(spacing: 12) {
                    ForEach(readings, id: \.date) { reading in
                        HStack {
                            time(of: reading)
                            Spacer()
                            glucose(of: reading)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(readings, id: \.date) { reading in
                        VStack(alignment: .leading, spacing: 2) {
                            time(of: reading)
                            glucose(of: reading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .font(.subheadline)
        }

        private func time(of reading: BasalTestReading) -> some View {
            Text(reading.date.formatted(date: .omitted, time: .shortened))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
        }

        private func glucose(of reading: BasalTestReading) -> some View {
            Text(state.formatWithUnits(reading.glucose))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}
