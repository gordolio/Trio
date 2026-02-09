import SwiftUI

extension CarbRatioCalibration {
    struct PreflightCheckView: View {
        @Bindable var state: StateModel
        @State private var showInfoSheet = false

        var body: some View {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "checklist")
                            .font(.system(size: 48))
                            .foregroundColor(.accentColor)

                        HStack(spacing: 6) {
                            Text("Pre-flight Checks")
                                .font(.title2)
                                .fontWeight(.semibold)

                            Button {
                                showInfoSheet = true
                            } label: {
                                Image(systemName: "info.circle")
                                    .font(.title3)
                                    .foregroundColor(.accentColor)
                            }
                        }

                        Text("Let's make sure conditions are right for an accurate test.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top)

                    // Checklist
                    VStack(spacing: 16) {
                        checkItem(
                            title: "Blood Glucose \(state.targetRangeDescription)",
                            subtitle: state.currentGlucose
                                .map { "\(state.formatGlucose($0)) \(state.unitsLabel)" } ?? "Loading...",
                            passed: state.isGlucoseInRange
                        )

                        checkItem(
                            title: "Glucose Trend Flat",
                            subtitle: state.glucoseFlatSubtitle,
                            passed: state.isGlucoseFlat,
                            explanation: "Glucose must not change by more than 15 mg/dL over the last ~45 minutes. This ensures a stable baseline so the test result is accurate."
                        )

                        checkItem(
                            title: "IOB Near Zero",
                            subtitle: state.iobSubtitle,
                            passed: state.isIOBNearZero
                        )

                        checkItem(
                            title: "COB Near Zero",
                            subtitle: "\(state.currentCOB.formatted(.number.precision(.fractionLength(0))))g on board",
                            passed: state.isCOBNearZero
                        )
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)

                    // Current Carb Ratio Info
                    VStack(spacing: 8) {
                        Text("Current Carb Ratio")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Text("\(state.currentCarbRatio.formatted(.number.precision(.fractionLength(1)))) g/U")
                            .font(.title)
                            .fontWeight(.bold)

                        Text(
                            "1 unit of insulin covers \(state.currentCarbRatio.formatted(.number.precision(.fractionLength(1))))g of carbs"
                        )
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)

                    Spacer()

                    // Action buttons
                    VStack(spacing: 12) {
                        Button {
                            state.requestBeginPrep()
                        } label: {
                            Text("Begin Prep")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!state.preflightPassed)
                    }
                }
            }
            .alert("Begin Calibration Prep?", isPresented: $state.showPrepConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Begin Prep") {
                    Task { await state.confirmBeginPrep() }
                }
            } message: {
                Text(
                    "During prep, a 'Calibration Mode' override will be activated to disable Super Micro Boluses (SMB). Your basal rate will continue normally. The override will be removed when the test completes or is cancelled. Any currently active override will be replaced."
                )
            }
            .sheet(isPresented: $showInfoSheet) {
                calibrationInfoSheet
            }
        }

        // MARK: - Calibration Info Sheet

        private var calibrationInfoSheet: some View {
            NavigationView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Overview
                        VStack(alignment: .leading, spacing: 8) {
                            Label("What is this?", systemImage: "questionmark.circle.fill")
                                .font(.headline)

                            Text(
                                "This test checks whether your Carb Ratio (CR) setting is accurate by measuring how your glucose responds to a known amount of carbs and insulin."
                            )
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        }

                        Divider()

                        // Steps
                        VStack(alignment: .leading, spacing: 16) {
                            Label("How it works", systemImage: "list.number")
                                .font(.headline)

                            stepRow(
                                number: "1",
                                title: "Pre-flight Checks",
                                detail: "Verifies glucose is in range (90–120 mg/dL), trend is flat, and IOB/COB are near zero."
                            )

                            stepRow(
                                number: "2",
                                title: "Prep Phase",
                                detail: "SMB (Super Micro Bolus) is temporarily disabled so only your basal rate runs. Conditions are monitored until stable."
                            )

                            stepRow(
                                number: "3",
                                title: "Test Phase",
                                detail: "You eat a specific number of glucose tablets (known carbs) and deliver a matching insulin bolus."
                            )

                            stepRow(
                                number: "4",
                                title: "Watch (90 min)",
                                detail: "The app monitors your glucose for 90 minutes to see how it responds to the carbs + bolus."
                            )

                            stepRow(
                                number: "5",
                                title: "Results",
                                detail: "Compares starting vs ending glucose. If glucose stayed flat, your CR is correct. If it rose or dropped, a new CR is suggested."
                            )
                        }

                        Divider()

                        // Key details
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Key details", systemImage: "info.circle.fill")
                                .font(.headline)

                            bulletPoint("Your basal rate continues normally throughout the test.")
                            bulletPoint("SMB is disabled during prep and re-enabled when the test finishes or is cancelled.")
                            bulletPoint("The test takes about 90 minutes after consuming tablets.")
                            bulletPoint("A notification will alert you when the observation period is complete.")
                            bulletPoint("You can cancel at any time — SMB settings will be restored immediately.")
                        }
                    }
                    .padding()
                }
                .navigationTitle("Calibration Info")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            showInfoSheet = false
                        }
                    }
                }
            }
        }

        @ViewBuilder private func stepRow(number: String, title: String, detail: String) -> some View {
            HStack(alignment: .top, spacing: 12) {
                Text(number)
                    .font(.caption.bold())
                    .foregroundColor(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.accentColor)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Text(detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }

        @ViewBuilder private func bulletPoint(_ text: String) -> some View {
            HStack(alignment: .top, spacing: 8) {
                Text("•")
                    .font(.subheadline)
                    .foregroundColor(.accentColor)

                Text(text)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }

        @ViewBuilder private func checkItem(
            title: String,
            subtitle: String,
            passed: Bool,
            explanation: String? = nil
        ) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Image(systemName: passed ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundColor(passed ? .green : .secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                }

                if let explanation, !passed {
                    Text(explanation)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.leading, 44) // align with text (icon width + spacing)
                }
            }
        }
    }
}

#Preview {
    CarbRatioCalibration.PreflightCheckView(state: CarbRatioCalibration.StateModel())
}
