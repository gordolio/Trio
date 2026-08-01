import SwiftUI

extension CarbRatioCalibration {
    struct TestPhaseView: View {
        @Bindable var state: StateModel
        @State private var showCancelConfirmation = false

        var body: some View {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "pill.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.accentColor)

                        Text("Time to Test")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text("Select your glucose tablets and confirm consumption to start the test.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top)

                    // Tablet Selection
                    VStack(spacing: 16) {
                        Text("Glucose Tablets")
                            .font(.headline)

                        // Brand selector
                        GlucoseTabletSelector(selectedBrand: $state.selectedBrand)

                        // Tablet count
                        HStack {
                            Text("Number of tablets:")
                                .font(.subheadline)

                            Spacer()

                            Stepper(value: $state.tabletCount, in: 1 ... 4) {
                                Text("\(state.tabletCount)")
                                    .font(.title3)
                                    .fontWeight(.semibold)
                                    .frame(minWidth: 30)
                            }
                        }
                        .padding()
                        .background(Color(.tertiarySystemBackground))
                        .cornerRadius(8)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)

                    // Calculation summary
                    VStack(spacing: 12) {
                        Text("Test Summary")
                            .font(.headline)

                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Total Carbs")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("\(state.totalCarbs.formatted())g")
                                    .font(.title2)
                                    .fontWeight(.semibold)
                            }

                            Spacer()

                            Image(systemName: "divide")
                                .foregroundColor(.secondary)

                            Spacer()

                            VStack(alignment: .center, spacing: 4) {
                                Text("Carb Ratio")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("\(state.currentCarbRatio.formatted(.number.precision(.fractionLength(1)))) g/U")
                                    .font(.title2)
                                    .fontWeight(.semibold)
                            }

                            Spacer()

                            Image(systemName: "equal")
                                .foregroundColor(.secondary)

                            Spacer()

                            VStack(alignment: .trailing, spacing: 4) {
                                Text("Bolus")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("\(state.calculatedBolus.formatted(.number.precision(.fractionLength(2))))U")
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .padding()
                        .background(Color(.tertiarySystemBackground))
                        .cornerRadius(8)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)

                    // Instructions
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Instructions")
                            .font(.headline)

                        instructionRow(
                            number: 1,
                            text: "Take \(state.tabletCount) \(state.selectedBrand.displayName) tablets now"
                        )
                        instructionRow(number: 2, text: "Chew and swallow completely")
                        instructionRow(number: 3, text: "Tap the button below to deliver bolus")
                        instructionRow(number: 4, text: "Do not eat or bolus for 90 minutes")
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)

                    Spacer()

                    // Action buttons
                    VStack(spacing: 12) {
                        Button {
                            state.confirmTabletsConsumed()
                        } label: {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                Text("I've Taken the Tablets")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button(role: .destructive) {
                            showCancelConfirmation = true
                        } label: {
                            Text("Cancel Test")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .confirmationDialog(
                "Cancel Calibration Test?",
                isPresented: $showCancelConfirmation,
                titleVisibility: .visible
            ) {
                Button("Cancel Test", role: .destructive) {
                    Task { await state.cancelTest() }
                }
                Button("Continue", role: .cancel) {}
            } message: {
                Text(
                    "This will cancel the calibration test, deactivate the calibration override, and restore your previous settings. Any progress will be lost."
                )
            }
        }

        @ViewBuilder private func instructionRow(number: Int, text: String) -> some View {
            HStack(spacing: 12) {
                Text("\(number)")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .frame(width: 24, height: 24)
                    .background(Color.accentColor)
                    .clipShape(Circle())

                Text(text)
                    .font(.subheadline)
            }
        }
    }
}

// MARK: - Glucose Tablet Selector

extension CarbRatioCalibration {
    struct GlucoseTabletSelector: View {
        @Binding var selectedBrand: GlucoseTabletBrand

        var body: some View {
            ForEach(GlucoseTabletBrand.allCases) { brand in
                tabletBrandCard(brand: brand)
            }
        }

        @ViewBuilder private func tabletBrandCard(brand: GlucoseTabletBrand) -> some View {
            Button {
                selectedBrand = brand
            } label: {
                HStack(spacing: 16) {
                    // Placeholder for tablet image
                    // In production, use: Image(brand.imageName)
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.orange.opacity(0.2))
                            .frame(width: 60, height: 60)

                        Image(systemName: "pill.fill")
                            .font(.title)
                            .foregroundColor(.orange)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(brand.displayName)
                            .font(.headline)
                            .foregroundColor(.primary)

                        Text("\(brand.carbsPerTablet.formatted())g carbs per tablet")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text(brand.description)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if selectedBrand == brand {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                    } else {
                        Image(systemName: "circle")
                            .font(.title2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(selectedBrand == brand ? Color.accentColor : Color.clear, lineWidth: 2)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(.tertiarySystemBackground))
                        )
                )
            }
            .buttonStyle(.plain)
        }
    }
}

#Preview {
    CarbRatioCalibration.TestPhaseView(state: CarbRatioCalibration.StateModel())
}
