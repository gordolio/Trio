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
        /// What the readings mean for the dose, shown once there is a recent reading.
        let status: String

        var body: some View {
            SettingsTestCard(title: String(localized: "Waiting for your glucose to level off")) {
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
                } else {
                    Text(status)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !state.recentReadings.isEmpty {
                    Divider()
                    ForEach(state.recentReadings.prefix(4), id: \.date) { reading in
                        HStack {
                            Text(reading.date.formatted(date: .omitted, time: .shortened))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(state.formatWithUnits(reading.glucose))
                                .monospacedDigit()
                        }
                        .font(.subheadline)
                    }
                }
            }
        }
    }
}
