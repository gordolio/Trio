import SwiftUI

extension BasalTest {
    struct CheckView: View {
        @Bindable var state: StateModel

        var body: some View {
            SettingsTestScreen {
                SettingsTestHeader(
                    icon: "waveform.path.ecg",
                    title: String(localized: "Check Your Basal"),
                    subtitle: String(
                        localized: "You fast for a few hours with Trio holding back its adjustments. If glucose stays flat, your basal rates are doing their job."
                    )
                )

                SettingsTestCard(title: String(localized: "Ready to start?")) {
                    ForEach(state.checks) { check in
                        SettingsTestCheckRow(title: check.title, detail: check.detail, state: check.state)
                    }
                }

                SettingsTestCard(title: String(localized: "How long to fast")) {
                    Picker("Hours", selection: $state.selectedHours) {
                        ForEach(Config.durationChoices, id: \.self) { hours in
                            Text("\(hours) h").tag(hours)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(
                        "Longer shows more, but covers more of the day. Test each part of the day separately: overnight, morning, afternoon and evening."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                SettingsTestCard(title: String(localized: "While Basal Testing is on")) {
                    bullet("Trio won't correct highs, give SMBs, or adjust for sensitivity.")
                    bullet("If glucose falls too low, Trio stops basal, and the test ends.")
                    bullet("Your usual dosing mode returns when the test ends.")
                }
            } footer: {
                Button {
                    state.requestStart()
                } label: {
                    Text("Start \(state.selectedHours)-Hour Fast")
                }
                .buttonStyle(.testPrimary)
                .disabled(!state.readyToStart)

                if !state.readyToStart {
                    Text("\(state.passingCount) of \(state.checks.count) checks passing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .alert("Start the fast?", isPresented: $state.showStartConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Start") { state.confirmStart() }
            } message: {
                Text(
                    "Trio switches to Basal Testing for \(state.selectedHours) hours and then returns to \(state.currentMode.displayName). Don't eat or give insulin until the test ends."
                )
            }
        }

        private func bullet(_ text: LocalizedStringKey) -> some View {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 5))
                    .padding(.top, 6)
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
