import LoopKit
import LoopKitUI
import SwiftUI
import Swinject

extension CGMSettings {
    struct CustomCGMOptionsView: BaseView {
        let resolver: Resolver
        @ObservedObject var state: CGMSettings.StateModel
        let cgmCurrent: CGMModel
        let deleteCGM: () -> Void

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState
        @Environment(\.presentationMode) var presentationMode

        @State private var shouldDisplayDeletionConfirmation: Bool = false

        // Simulator settings — use object(forKey:) nil checks so that 0 is preserved as a valid saved value
        @State private var centerValue: Double = {
            UserDefaults.standard.object(forKey: "GlucoseSimulator_CenterValue") != nil
                ? UserDefaults.standard.double(forKey: "GlucoseSimulator_CenterValue")
                : OscillatingGenerator.Defaults.centerValue
        }()

        @State private var amplitude: Double = {
            UserDefaults.standard.object(forKey: "GlucoseSimulator_Amplitude") != nil
                ? UserDefaults.standard.double(forKey: "GlucoseSimulator_Amplitude")
                : OscillatingGenerator.Defaults.amplitude
        }()

        @State private var period: Double = {
            UserDefaults.standard.object(forKey: "GlucoseSimulator_Period") != nil
                ? UserDefaults.standard.double(forKey: "GlucoseSimulator_Period")
                : OscillatingGenerator.Defaults.period
        }()

        @State private var noiseAmplitude: Double = {
            UserDefaults.standard.object(forKey: "GlucoseSimulator_NoiseAmplitude") != nil
                ? UserDefaults.standard.double(forKey: "GlucoseSimulator_NoiseAmplitude")
                : OscillatingGenerator.Defaults.noiseAmplitude
        }()

        @State private var produceStaleValues: Bool = UserDefaults.standard.bool(forKey: "GlucoseSimulator_ProduceStaleValues")

        // Tablet simulation settings
        @State private var tabletTargetDelta: Double = {
            UserDefaults.standard.object(forKey: "GlucoseSimulator_TabletTargetDelta") != nil
                ? UserDefaults.standard.double(forKey: "GlucoseSimulator_TabletTargetDelta")
                : OscillatingGenerator.Defaults.tabletTargetDelta
        }()

        @State private var isTabletActive: Bool = false

        // Timer for live BG preview updates
        @State private var now = Date()
        private let previewTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

        /// Drives the synthetic `cgmStatusHighlight`
        @State private var simulatedScenarioRaw: String = UserDefaults.standard
            .string(forKey: "GlucoseSimulator.simulatedScenario") ?? SimulatedSensorScenario.runningNormally.rawValue

        /// Routes "open URL failed" warnings through `TrioAlertManager` so
        /// they share the same in-app banner UI as the rest of the alert
        /// pipeline (no more SwiftMessages roundtrip).
        private func warnOpenFailed(identifier: String, title: String, body: String) {
            let content = Alert.Content(
                title: title,
                body: body,
                acknowledgeActionButtonLabel: String(localized: "OK")
            )
            let alert = Alert(
                identifier: Alert.Identifier(managerIdentifier: "trio.cgmSettings", alertIdentifier: identifier),
                foregroundContent: content,
                backgroundContent: content,
                trigger: .immediate,
                interruptionLevel: .active,
                sound: nil
            )
            resolver.resolve(TrioAlertManager.self)?.issueAlert(alert)
        }

        // Refresh state from UserDefaults on view appear (handles returning to this screen after changes)
        private func initializeSimulatorSettings() {
            // Re-read all values from UserDefaults/OscillatingGenerator to pick up any external changes
            let gen = OscillatingGenerator()
            isTabletActive = gen.isTabletActive
        }

        // Save simulator settings to UserDefaults
        private func saveSimulatorSettings() {
            UserDefaults.standard.set(centerValue, forKey: "GlucoseSimulator_CenterValue")
            UserDefaults.standard.set(amplitude, forKey: "GlucoseSimulator_Amplitude")
            UserDefaults.standard.set(period, forKey: "GlucoseSimulator_Period")
            UserDefaults.standard.set(noiseAmplitude, forKey: "GlucoseSimulator_NoiseAmplitude")
            UserDefaults.standard.set(produceStaleValues, forKey: "GlucoseSimulator_ProduceStaleValues")
            UserDefaults.standard.set(tabletTargetDelta, forKey: "GlucoseSimulator_TabletTargetDelta")
        }

        var body: some View {
            NavigationView {
                Form {
                    if cgmCurrent.type != .none {
                        if cgmCurrent.type == .nightscout {
                            nightscoutSection
                        } else if cgmCurrent.type == .xdrip {
                            xDripConfigurationSection
                        } else if cgmCurrent.type == .simulator {
                            simulatorConfigurationSection
                        }

                        if let appURL = cgmCurrent.type.appURL {
                            Section {
                                Button {
                                    UIApplication.shared.open(appURL, options: [:]) { success in
                                        if !success {
                                            warnOpenFailed(
                                                identifier: "cgm.app.open.failed",
                                                title: String(localized: "Open failed"),
                                                body: String(localized: "Unable to open the app")
                                            )
                                        }
                                    }
                                }

                                label: {
                                    Label(
                                        "Open \(cgmCurrent.displayName)",
                                        systemImage: "waveform.path.ecg.rectangle"
                                    ).font(.title3)
                                        .padding() }
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .buttonStyle(.bordered)
                            }.listRowBackground(Color.clear)
                        }
                    }
                }
                .navigationTitle(cgmCurrent.displayName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    /// proper positioning should be .leading
                    /// LoopKit submodules set placement to .trailing; we'll keep it "proper" here
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") {
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                }
                .safeAreaInset(
                    edge: .bottom,
                    spacing: 0
                ) {
                    stickyDeleteButton
                }
                .scrollContentBackground(.hidden)
                .background(appState.trioBackgroundColor(for: colorScheme))
                .glassActionSheet(
                    "Delete CGM",
                    message: Text("Are you sure you want to delete \(cgmCurrent.displayName)?"),
                    isPresented: $shouldDisplayDeletionConfirmation,
                    actions: [
                        GlassSheetAction("Delete \(cgmCurrent.displayName)", role: .destructive) {
                            deleteCGM()
                        }
                    ]
                )
                .onAppear {
                    if cgmCurrent.type == .simulator {
                        initializeSimulatorSettings()
                    }
                }
                .onReceive(previewTimer) { now = $0 }
            }
        }

        /// Live preview of the simulator's current and next BG values
        private var simulatorBGPreview: some View {
            let gen = OscillatingGenerator()
            let currentBG = gen.previewGlucose(at: now)
            let nextBG = gen.previewGlucose(at: now.addingTimeInterval(300))
            let tabletOffset = gen.tabletEffect(at: now)

            return VStack(spacing: 8) {
                Text("BG Preview")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 0) {
                    VStack(spacing: 2) {
                        Text("Current")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(currentBG)")
                            .font(.title3.monospacedDigit())
                            .fontWeight(.semibold)
                        Text(state.units.rawValue)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)

                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                        .font(.caption)

                    VStack(spacing: 2) {
                        Text("Next (5 min)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(nextBG)")
                            .font(.title3.monospacedDigit())
                            .fontWeight(.semibold)
                        Text(state.units.rawValue)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)

                    if isTabletActive {
                        VStack(spacing: 2) {
                            Text("Tablet Effect")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(String(format: "%+.0f", tabletOffset))
                                .font(.title3.monospacedDigit())
                                .fontWeight(.semibold)
                                .foregroundStyle(tabletOffset > 0 ? .red : tabletOffset < 0 ? .blue : .primary)
                            Text(state.units.rawValue)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 4)
            }
            .padding(.bottom)
        }

        var nightscoutSection: some View {
            Group {
                Section(
                    header: Text("Configuration"),
                    content: {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("CGM is not used as heartbeat.").padding(.top)

                            Text(
                                state.url == nil ?
                                    "To configure your CGM, tap the button below. In the form that opens, enter your Nightscout credentials to connect to your instance." :
                                    "Tap the button below to open your Nightscout instance in your iPhone's default browser."
                            ).font(.footnote)
                                .foregroundStyle(Color.secondary)
                                .lineLimit(nil)
                                .padding(.vertical)
                        }

                        NavigationLink(
                            destination: NightscoutConfig.RootView(resolver: resolver, displayClose: false),
                            label: { Text("Configure Nightscout").foregroundStyle(Color.accentColor) }
                        )
                    }
                ).listRowBackground(Color.chart)

                if let url = state.url {
                    Section {
                        Button {
                            UIApplication.shared.open(url, options: [:]) { success in
                                if !success {
                                    warnOpenFailed(
                                        identifier: "nightscout.open.failed",
                                        title: String(localized: "Open failed"),
                                        body: String(localized: "No URL available")
                                    )
                                }
                            }
                        }
                        label: {
                            Label(
                                "Open Nightscout",
                                systemImage: "waveform.path.ecg.rectangle"
                            ).font(.title3)
                                .padding() }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .buttonStyle(.bordered)
                    }
                    .listRowBackground(Color.clear)
                }
            }
        }

        var xDripConfigurationSection: some View {
            Section(
                header: Text("Configuration"),
                content: {
                    VStack(alignment: .leading) {
                        if let cgmTransmitterDeviceAddress = UserDefaults.standard
                            .cgmTransmitterDeviceAddress
                        {
                            Text("CGM address :").padding(.top)
                            Text(cgmTransmitterDeviceAddress)
                        } else {
                            Text("CGM is not used as heartbeat.").padding(.top)
                        }

                        HStack(alignment: .center) {
                            Text(
                                "A heartbeat tells Trio to start a loop cycle. This is required for closed loop."
                            )
                            .font(.footnote)
                            .foregroundStyle(Color.secondary)
                            .lineLimit(nil)
                            Spacer()
                        }.padding(.vertical)

                        if let link = cgmCurrent.type.externalLink {
                            Button {
                                UIApplication.shared.open(link, options: [:], completionHandler: nil)
                            } label: {
                                HStack {
                                    Text("About this source")
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            ).listRowBackground(Color.chart)
        }

        var simulatorConfigurationSection: some View {
            Group {
                Section(
                    header: Text("Configuration"),
                    content: {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("CGM is not used as heartbeat.").lineLimit(nil)
                                .padding(.top)

                            Text("Glucose trace WILL NOT be affected by any insulin or carb entries.").lineLimit(nil)
                                .bold()
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text(
                                "The simulator creates a wave-like pattern that mimics natural glucose fluctuations throughout the day."
                            ).lineLimit(nil)

                            Text("Configuration changes will take effect on the next glucose reading.")
                                .padding(.bottom).lineLimit(nil)
                        }.foregroundStyle(Color.secondary).font(.footnote)
                    }
                ).listRowBackground(Color.chart)

                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: $produceStaleValues) {
                            VStack(alignment: .leading) {
                                Text("Produce Stale Values")
                            }
                        }
                        .padding(.top)
                        .onChange(of: produceStaleValues) { _, newValue in
                            UserDefaults.standard.set(newValue, forKey: "GlucoseSimulator_ProduceStaleValues")
                        }

                        Text(
                            "When stale values are enabled, the simulator will repeatedly output the last generated glucose value."
                        )
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(nil)
                        .padding(.bottom)
                    }
                }.listRowBackground(Color.chart)

                Section(
                    header: Text("Sensor Lifecycle Scenario"),
                    footer: Text(
                        "Drives the outer-ring + tag on the home screen's glucose bobble."
                    )
                ) {
                    Picker("Scenario", selection: $simulatedScenarioRaw) {
                        ForEach(SimulatedSensorScenario.allCases) { scenario in
                            Text(scenario.displayName).tag(scenario.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: simulatedScenarioRaw) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "GlucoseSimulator.simulatedScenario")
                        // Push the change through the active simulator
                        // instance so subjects emit immediately.
                        if let scenario = SimulatedSensorScenario(rawValue: newValue),
                           let sim = resolver.resolve(FetchGlucoseManager.self)?.glucoseSource as? GlucoseSimulatorSource
                        {
                            sim.applySimulatedScenario(scenario)
                        }
                    }

                    if let scenario = SimulatedSensorScenario(rawValue: simulatedScenarioRaw) {
                        Text(scenario.devNotes)
                            .font(.footnote)
                            .foregroundStyle(Color.secondary)
                            .lineLimit(nil)
                    }
                }.listRowBackground(Color.chart)

                if !produceStaleValues {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Center Value:").bold()

                                Spacer()

                                Text(state.units == .mgdL ? centerValue.description : centerValue.formattedAsMmolL).bold()

                                Text(state.units.rawValue).foregroundStyle(Color.secondary)
                            }.padding(.top)

                            Slider(value: $centerValue, in: 80 ... 200, step: 1)
                                .accentColor(.accentColor)
                                .onChange(of: centerValue) { _, newValue in
                                    UserDefaults.standard.set(newValue, forKey: "GlucoseSimulator_CenterValue")
                                }
                                .padding(.vertical)

                            Text("The average glucose level around which values will oscillate.")
                                .font(.footnote)
                                .foregroundStyle(Color.secondary)
                                .lineLimit(nil)
                                .padding(.bottom)
                        }
                    }.listRowBackground(Color.chart)

                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Amplitude:").bold()

                                Spacer()

                                Text("±")
                                Text(state.units == .mgdL ? amplitude.description : amplitude.formattedAsMmolL).bold()

                                Text(state.units.rawValue).foregroundStyle(Color.secondary)
                            }.padding(.top)

                            Slider(value: $amplitude, in: 10 ... 100, step: 5)
                                .accentColor(.accentColor)
                                .onChange(of: amplitude) { _, newValue in
                                    UserDefaults.standard.set(newValue, forKey: "GlucoseSimulator_Amplitude")
                                }
                                .padding(.vertical)

                            Text(
                                "Range: \(state.units == .mgdL ? (centerValue - amplitude).description : (centerValue - amplitude).formattedAsMmolL)–\(state.units == .mgdL ? (centerValue + amplitude).description : (centerValue + amplitude).formattedAsMmolL) \(state.units.rawValue)"
                            )
                            .bold()
                            .font(.footnote)
                            .foregroundStyle(Color.secondary)
                            .lineLimit(nil)

                            Text("The maximum deviation from the center value. Higher values create wider swings.")
                                .font(.footnote)
                                .foregroundStyle(Color.secondary)
                                .lineLimit(nil)
                                .padding(.bottom)
                        }
                    }.listRowBackground(Color.chart)

                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Period:").bold()

                                Spacer()

                                Text(Int(period / 3600).description).bold()

                                Text("hours").foregroundStyle(Color.secondary)
                            }.padding(.top)

                            Slider(value: $period, in: 3600 ... 21600, step: 1800)
                                .accentColor(.accentColor)
                                .onChange(of: period) { _, newValue in
                                    UserDefaults.standard.set(newValue, forKey: "GlucoseSimulator_Period")
                                }
                                .padding(.vertical)

                            Text("The time it takes to complete one full cycle from high to low and back to high.")
                                .font(.footnote)
                                .foregroundStyle(Color.secondary)
                                .lineLimit(nil)
                                .padding(.bottom)
                        }
                    }.listRowBackground(Color.chart)

                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Noise:").bold()

                                Spacer()

                                Text("±")

                                Text(state.units == .mgdL ? noiseAmplitude.description : noiseAmplitude.formattedAsMmolL).bold()

                                Text(state.units.rawValue).foregroundStyle(Color.secondary)
                            }.padding(.top)

                            Slider(value: $noiseAmplitude, in: 0 ... 20, step: 1)
                                .accentColor(.accentColor)
                                .onChange(of: noiseAmplitude) { _, newValue in
                                    UserDefaults.standard.set(newValue, forKey: "GlucoseSimulator_NoiseAmplitude")
                                }
                                .padding(.vertical)

                            Text("Random variation added to each reading to simulate real-world sensor noise.")
                                .font(.footnote)
                                .foregroundStyle(Color.secondary)
                                .lineLimit(nil)
                                .padding(.bottom)
                        }
                    }.listRowBackground(Color.chart)
                }

                // MARK: - Glucose Tablet Simulation

                Section(header: Text("Glucose Tablet Simulation")) {
                    VStack(alignment: .leading, spacing: 10) {
                        // Settings guidance banner — shown when amplitude or noise are too high for reliable calibration testing
                        if amplitude > 10 || noiseAmplitude > 2 {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Recommended: Reduce Simulator Noise", systemImage: "exclamationmark.triangle.fill")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.orange)

                                Text(
                                    "For calibration testing, use a quiet glucose trace so preflight checks pass. Reduce amplitude to ≤10 and noise to 0."
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(nil)

                                Button {
                                    // Apply quiet-mode settings for calibration testing
                                    centerValue = 105
                                    amplitude = 5
                                    noiseAmplitude = 0
                                    period = 21600 // 6 hours — slowest cycle
                                    saveSimulatorSettings()
                                } label: {
                                    Label("Apply Quiet Settings", systemImage: "waveform.path")
                                        .font(.subheadline.weight(.medium))
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .tint(.orange)
                            }
                            .padding(.vertical, 6)

                            Divider()
                        }

                        // Target delta slider header
                        HStack {
                            Text("Target Delta at 90 min:").bold()
                            Spacer()
                            Text(
                                state.units == .mgdL
                                    ? String(format: "%+.0f", tabletTargetDelta)
                                    : String(format: "%+.1f", tabletTargetDelta / 18.0)
                            ).bold()
                            Text(state.units.rawValue).foregroundStyle(Color.secondary)
                        }.padding(.top)

                        // Target delta slider: -50 to +50 mg/dL
                        Slider(value: $tabletTargetDelta, in: -50 ... 50, step: 5)
                            .accentColor(.accentColor)
                            .onChange(of: tabletTargetDelta) { _, newValue in
                                UserDefaults.standard.set(newValue, forKey: "GlucoseSimulator_TabletTargetDelta")
                            }
                            .padding(.vertical)

                        // Preset buttons for the three calibration test scenarios
                        HStack(spacing: 8) {
                            Button("Correct (0)") {
                                tabletTargetDelta = 0
                                UserDefaults.standard.set(0.0, forKey: "GlucoseSimulator_TabletTargetDelta")
                            }
                            .buttonStyle(.bordered)
                            .font(.caption)

                            Button("Strong (-25)") {
                                tabletTargetDelta = -25
                                UserDefaults.standard.set(-25.0, forKey: "GlucoseSimulator_TabletTargetDelta")
                            }
                            .buttonStyle(.bordered)
                            .font(.caption)

                            Button("Weak (+25)") {
                                tabletTargetDelta = 25
                                UserDefaults.standard.set(25.0, forKey: "GlucoseSimulator_TabletTargetDelta")
                            }
                            .buttonStyle(.bordered)
                            .font(.caption)
                        }
                        .padding(.bottom, 4)

                        // Dynamic explanation based on current delta value
                        Group {
                            if tabletTargetDelta > 0 {
                                Text(
                                    "Glucose will rise, then partially come back down, settling at +\(Int(tabletTargetDelta)) mg/dL after 90 min. Calibration will suggest lowering your CR (ratio too weak)."
                                )
                            } else if tabletTargetDelta < 0 {
                                Text(
                                    "Glucose will rise from carbs, then insulin pulls it below baseline to \(Int(tabletTargetDelta)) mg/dL after 90 min. Calibration will suggest raising your CR (ratio too strong)."
                                )
                            } else {
                                Text(
                                    "Glucose will rise from carbs then return to baseline by 90 min. Calibration will confirm your CR is correct."
                                )
                            }
                        }
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(nil)

                        Divider()

                        // Take Tablet button / Active Tablet status
                        if isTabletActive {
                            HStack {
                                Image(systemName: "pills.fill")
                                    .foregroundStyle(.green)
                                Text("Tablet Active")
                                    .bold()
                                    .foregroundStyle(.green)
                                Spacer()
                                Button("Clear") {
                                    UserDefaults.standard.set(0.0, forKey: "GlucoseSimulator_TabletTakenDate")
                                    isTabletActive = false
                                }
                                .foregroundStyle(.red)
                                .buttonStyle(.bordered)
                                .font(.caption)
                            }
                            .padding(.vertical, 4)
                        } else {
                            Button {
                                OscillatingGenerator().simulateTablet()
                                isTabletActive = true
                            } label: {
                                Label("Simulate Glucose Tablet", systemImage: "pills.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .padding(.vertical, 4)
                        }

                        Text(
                            "The tablet starts a glucose response curve that peaks at ~24 min and reaches the target delta at 90 min. The effect clears automatically after 120 min."
                        )
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(nil)

                        Divider()

                        // Live BG preview
                        simulatorBGPreview
                    }
                }.listRowBackground(Color.chart)

                Section {
                    Button(action: {
                        centerValue = OscillatingGenerator.Defaults.centerValue
                        amplitude = OscillatingGenerator.Defaults.amplitude
                        period = OscillatingGenerator.Defaults.period
                        noiseAmplitude = OscillatingGenerator.Defaults.noiseAmplitude
                        produceStaleValues = OscillatingGenerator.Defaults.produceStaleValues
                        tabletTargetDelta = OscillatingGenerator.Defaults.tabletTargetDelta
                        UserDefaults.standard.set(0.0, forKey: "GlucoseSimulator_TabletTakenDate")
                        isTabletActive = false
                        saveSimulatorSettings()
                    }, label: {
                        Text("Reset to Defaults")

                    })
                        .frame(maxWidth: .infinity, alignment: .center)
                        .tint(.white)
                }.listRowBackground(Color.accentColor)

            }.listSectionSpacing(sectionSpacing)
        }

        var stickyDeleteButton: some View {
            ZStack {
                Rectangle()
                    .frame(width: UIScreen.main.bounds.width, height: 120)
                    .foregroundStyle(colorScheme == .dark ? Color.bgDarkerDarkBlue : Color.white)
                    .background(.thinMaterial)
                    .opacity(0.8)
                    .clipShape(Rectangle())
                    .padding(.bottom, -55)

                Button(action: {
                    shouldDisplayDeletionConfirmation.toggle()
                }, label: {
                    Text("Delete CGM")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(10)
                })
                    .frame(width: UIScreen.main.bounds.width * 0.9, height: 40, alignment: .center)
                    .background(Color(.systemRed))
                    .tint(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(5)
            }
        }
    }
}
