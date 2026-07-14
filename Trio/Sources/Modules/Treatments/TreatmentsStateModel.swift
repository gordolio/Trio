import Combine
import CoreData
import Foundation
import LocalAuthentication
import LoopKit
import Observation
import SwiftUI
import Swinject

extension Treatments {
    @Observable final class StateModel: BaseStateModel<Provider> {
        @ObservationIgnored @Injected() var unlockmanager: UnlockManager!
        @ObservationIgnored @Injected() var apsManager: APSManager!
        @ObservationIgnored @Injected() var broadcaster: Broadcaster!
        @ObservationIgnored @Injected() var pumpHistoryStorage: PumpHistoryStorage!
        @ObservationIgnored @Injected() var settings: SettingsManager!
        @ObservationIgnored @Injected() var nsManager: NightscoutManager!
        @ObservationIgnored @Injected() var carbsStorage: CarbsStorage!
        @ObservationIgnored @Injected() var glucoseStorage: GlucoseStorage!
        @ObservationIgnored @Injected() var determinationStorage: DeterminationStorage!
        @ObservationIgnored @Injected() var bolusCalculationManager: BolusCalculationManager!
        @ObservationIgnored @Injected() var calibrationService: CalibrationModeService!

        var lowGlucose: Decimal = 70
        var highGlucose: Decimal = 180
        var glucoseColorScheme: GlucoseColorScheme = .staticColor

        var predictions: Predictions?
        var amount: Decimal = 0
        var insulinRecommended: Decimal = 0
        var insulinRequired: Decimal = 0
        var units: GlucoseUnits = .mgdL
        var threshold: Decimal = 0
        var maxBolus: Decimal = 0
        var maxExternal: Decimal { maxBolus * 3 }
        var maxIOB: Decimal = 0
        var maxCOB: Decimal = 0
        var errorString: Decimal = 0
        var evBG: Decimal = 0
        var insulin: Decimal = 0
        var isf: Decimal = 0
        var error: Bool = false
        var minGuardBG: Decimal = 0
        var minDelta: Decimal = 0
        var expectedDelta: Decimal = 0
        var minPredBG: Decimal = 0
        var lastLoopDate: Date?
        var isAwaitingDeterminationResult: Bool = false
        var carbRatio: Decimal = 0

        var addButtonPressed: Bool = false

        /// Whether a carb ratio calibration test is currently in an active phase
        var isCalibrationActive: Bool {
            guard let phase = calibrationService?.currentTest?.phase else { return false }
            switch phase {
            case .awaitingTabletConfirmation,
                 .bolusDelivered,
                 .observing,
                 .prepping,
                 .readyToTest:
                return true
            default:
                return false
            }
        }

        /// Description of the current calibration phase for display
        var calibrationPhaseDescription: String {
            calibrationService?.currentTest?.phase.displayName ?? ""
        }

        var target: Decimal = 0
        var cob: Int16 = 0
        var iob: Decimal = 0

        var currentBG: Decimal = 0
        var fifteenMinInsulin: Decimal = 0
        var deltaBG: Decimal = 0
        var targetDifferenceInsulin: Decimal = 0
        var targetDifference: Decimal = 0
        var wholeCob: Decimal = 0
        var wholeCobInsulin: Decimal = 0
        var iobInsulinReduction: Decimal = 0
        var wholeCalc: Decimal = 0
        var factoredInsulin: Decimal = 0
        var insulinCalculated: Decimal = 0
        var fraction: Decimal = 0
        var basal: Decimal = 0
        var fattyMeals: Bool = false
        var fattyMealFactor: Decimal = 0
        var useFattyMealCorrectionFactor: Bool = false
        var displayPresets: Bool = true
        var confirmBolus: Bool = false

        var currentBasal: Decimal = 0
        var currentCarbRatio: Decimal = 0
        var currentBGTarget: Decimal = 0
        var currentISF: Decimal = 0

        var sweetMeals: Bool = false
        var sweetMealFactor: Decimal = 0
        var useSuperBolus: Bool = false
        var superBolusInsulin: Decimal = 0

        var meal: [CarbsEntry]?
        var carbs: Decimal = 0
        var fat: Decimal = 0
        var protein: Decimal = 0
        var note: String = ""

        var date = Date()
        let defaultDate = Date()

        var carbsRequired: Decimal?
        var useFPUconversion: Bool = false
        var dish: String = ""
        var selection: MealPresetStored?
        var summation: [String] = []
        var maxCarbs: Decimal = 0
        var maxFat: Decimal = 0
        var maxProtein: Decimal = 0

        var id_: String = ""
        var summary: String = ""

        // MARK: - AI-Assisted Entry Properties

        var isAnalyzingFood = false
        var aiError: String?
        var foodItemSelection: FoodItemSelection?
        var conversationManager: AIConversationManager?
        /// The captured photo data, kept visible for thumbnail display during and after analysis
        var capturedImageData: Data? {
            didSet {
                if capturedImageData == nil, oldValue != nil {
                    print("🔍 capturedImageData was SET TO NIL")
                    Thread.callStackSymbols.prefix(10).forEach { print("  \($0)") }
                }
            }
        }

        /// User-provided description/context for the food photo
        var foodDescription: String = ""
        var aiAssistedMetadata: AIAssistedCarbEntryMetadata?
        private var originalAICarbsQuantity: Double?
        private var pendingImageData: Data?
        private var pendingAnalysisDescription: String?

        /// Vision items saved before merge, used as fallback when user rejects published nutrition
        private var premergeVisionItems: [AIFoodItem]?
        /// Restaurant name from the published result, used for matching during reject
        private var publishedRestaurantName: String?

        // MARK: - Multi-Provider Comparison Mode

        /// Per-provider analysis slots. When multi-provider mode is off, only the single configured
        /// provider appears here. The `foodItemSelection` / `conversationManager` / `premergeVisionItems`
        /// / `publishedRestaurantName` values above mirror the slot for `displayedProvider`.
        var foodItemSelections: [AIProviderType: FoodItemSelection] = [:]
        var conversationManagers: [AIProviderType: AIConversationManager] = [:]
        var perProviderAnalyzing: [AIProviderType: Bool] = [:]
        var perProviderErrors: [AIProviderType: String] = [:]
        var perProviderPremergeVisionItems: [AIProviderType: [AIFoodItem]] = [:]
        var perProviderPublishedRestaurantName: [AIProviderType: String] = [:]

        /// Providers the current analysis was dispatched to, in display order.
        /// Empty when no analysis is in flight / complete.
        var activeProviders: [AIProviderType] = []

        /// Which provider's results are currently shown in the UI.
        /// Only meaningful when `activeProviders.count > 1` (multi-provider mode).
        var displayedProvider: AIProviderType?

        /// Whether we're in AI mode (photo captured or analysis complete)
        var isInAIMode: Bool {
            capturedImageData != nil || foodItemSelection != nil || isAnalyzingFood
        }

        var isAIAvailable: Bool {
            AIProviderType.allCases.contains(where: isProviderAvailable)
        }

        /// Whether the given provider has an API key configured in the build.
        func isProviderAvailable(_ provider: AIProviderType) -> Bool {
            let (infoKey, placeholder): (String, String)
            switch provider {
            case .openai:
                (infoKey, placeholder) = ("OpenAIAPIKey", "$(OPENAI_API_KEY)")
            case .claude:
                (infoKey, placeholder) = ("AnthropicAPIKey", "$(ANTHROPIC_API_KEY)")
            }
            guard let value = Bundle.main.object(forInfoDictionaryKey: infoKey) as? String,
                  !value.isEmpty, value != placeholder else { return false }
            return true
        }

        var autoOpenCamera: Bool = false

        var externalInsulin: Bool = false
        var showInfo: Bool = false
        var glucoseFromPersistence: [GlucoseStored] = []
        var determination: [OrefDetermination] = []
        var preprocessedData: [(id: UUID, forecast: Forecast, forecastValue: ForecastValue)] = []
        var predictionsForChart: Predictions?
        var simulatedDetermination: Determination?

        var minForecast: [Int] = []
        var maxForecast: [Int] = []
        @MainActor var minCount: Int = 12 // count of Forecasts drawn in 5 min distances, i.e. 12 means a min of 1 hour
        var forecastDisplayType: ForecastDisplayType = .cone
        var isSmoothingEnabled: Bool = false
        var stops: [Gradient.Stop] = []

        let now = Date.now

        let viewContext = CoreDataStack.shared.persistentContainer.viewContext

        var isActive: Bool = false

        var showDeterminationFailureAlert = false
        var determinationFailureMessage = ""

        // MARK: - NSFetchedResultsControllers

        //
        // Glucose, the latest determination and the last pump bolus are driven by
        // NSFetchedResultsControllers bound to the viewContext. They keep their `fetchedObjects`
        // continuously in sync and notify us through their delegate's `onContentChange` closure.

        @ObservationIgnored let glucoseControllerDelegate = FetchedResultsControllerDelegate()
        @ObservationIgnored private(set) lazy var glucoseController: NSFetchedResultsController<GlucoseStored> = {
            let request = NSFetchRequest<GlucoseStored>(entityName: "GlucoseStored")
            request.sortDescriptors = [NSSortDescriptor(keyPath: \GlucoseStored.date, ascending: false)]
            request.predicate = NSPredicate.glucose
            request.fetchBatchSize = 50
            let controller = NSFetchedResultsController(
                fetchRequest: request,
                managedObjectContext: viewContext,
                sectionNameKeyPath: nil,
                cacheName: nil
            )
            controller.delegate = glucoseControllerDelegate
            return controller
        }()

        @ObservationIgnored let determinationControllerDelegate = FetchedResultsControllerDelegate()
        @ObservationIgnored private(set) lazy var determinationController: NSFetchedResultsController<OrefDetermination> = {
            let request = NSFetchRequest<OrefDetermination>(entityName: "OrefDetermination")
            request.sortDescriptors = [NSSortDescriptor(keyPath: \OrefDetermination.deliverAt, ascending: false)]
            request.predicate = NSPredicate.predicateFor30MinAgoForDetermination
            request.fetchLimit = 1
            let controller = NSFetchedResultsController(
                fetchRequest: request,
                managedObjectContext: viewContext,
                sectionNameKeyPath: nil,
                cacheName: nil
            )
            controller.delegate = determinationControllerDelegate
            return controller
        }()

        @ObservationIgnored let lastBolusControllerDelegate = FetchedResultsControllerDelegate()
        @ObservationIgnored private(set) lazy var lastBolusController: NSFetchedResultsController<PumpEventStored> = {
            let request = NSFetchRequest<PumpEventStored>(entityName: "PumpEventStored")
            request.sortDescriptors = [NSSortDescriptor(keyPath: \PumpEventStored.timestamp, ascending: false)]
            request.predicate = NSPredicate.lastPumpBolus
            request.fetchLimit = 1
            let controller = NSFetchedResultsController(
                fetchRequest: request,
                managedObjectContext: viewContext,
                sectionNameKeyPath: nil,
                cacheName: nil
            )
            controller.delegate = lastBolusControllerDelegate
            return controller
        }()

        private var subscriptions = Set<AnyCancellable>()

        typealias PumpEvent = PumpEventStored.EventType

        var bolusProgress: Decimal?
        var bolusStatus: BolusStatus = .noBolus
        var lastPumpBolus: PumpEventStored?

        func unsubscribe() {
            subscriptions.forEach { $0.cancel() }
            subscriptions.removeAll()
        }

        override func subscribe() {
            guard isActive else {
                return
            }

            debug(.bolusState, "subscribe fired")
            setupBolusStateConcurrently()
            subscribeToBolusProgress()
        }

        deinit {
            debug(.bolusState, "StateModel deinit called")
        }

        private var hasCleanedUp = false

        /// In-flight work started by this instance; cancelled in `cleanupTreatmentState()`.
        @ObservationIgnored private var setupTask: Task<Void, Never>?
        @ObservationIgnored private var determinationUpdateTask: Task<Void, Never>?

        func cleanupTreatmentState() {
            guard !hasCleanedUp else { return }
            hasCleanedUp = true

            unsubscribe()
            lifetime = Lifetime()

            // Stop the FRC → recompute pipelines; a dismissed instance must not keep
            // re-running the bolus calculator on every viewContext merge.
            glucoseControllerDelegate.onContentChange = nil
            determinationControllerDelegate.onContentChange = nil
            lastBolusControllerDelegate.onContentChange = nil

            // Cancel in-flight work — the setup task awaits a full oref simulation.
            setupTask?.cancel()
            determinationUpdateTask?.cancel()

            broadcaster?.unregister(DeterminationObserver.self, observer: self)
            broadcaster?.unregister(BolusFailureObserver.self, observer: self)

            debug(.bolusState, "StateModel cleanup() finished")
        }

        private func setupBolusStateConcurrently() {
            debug(.bolusState, "Setting up bolus state concurrently...")
            setupTask = Task {
                // Load settings and observers first so the determination controller's initial
                // population (which runs calculateInsulin) sees correct values.
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            await self.getAllSettingsValues()
                        }
                        group.addTask {
                            await self.setupSettings()
                        }
                        group.addTask {
                            self.registerObservers()
                        }

                        // Wait for all tasks to complete
                        try await group.waitForAll()
                    }
                } catch let error as NSError {
                    debug(.default, "Failed to setup bolus state concurrently: \(error)")
                }

                // viewContext-bound FRCs: guard and wiring share one main-actor slice.
                await MainActor.run {
                    guard !Task.isCancelled, !self.hasCleanedUp else { return }
                    self.setupGlucoseController()
                    self.setupDeterminationController()
                    self.setupLastBolusController()
                }
            }
        }

        /// Mirrors `apsManager.bolusProgress` (a `CurrentValueSubject<Decimal?, Never>`) directly into the
        /// state model so the View can read both the progress fraction (0.0–1.0) and a derived in-progress
        /// flag. Stored in `lifetime` to match the Home module's pattern (HomeStateModel.registerObservers).
        private func subscribeToBolusProgress() {
            apsManager.bolusProgress
                .receive(on: DispatchQueue.main)
                .weakAssign(to: \.bolusProgress, on: self)
                .store(in: &lifetime)

            provider.deviceManager.bolusTrigger
                .receive(on: DispatchQueue.main)
                .weakAssign(to: \.bolusStatus, on: self)
                .store(in: &lifetime)
        }

        func cancelBolus() {
            Task {
                await apsManager.cancelBolus(nil)
                try? await apsManager.determineBasalSync()
            }
        }

        // MARK: - Basal

        private enum SettingType {
            case basal
            case carbRatio
            case bgTarget
            case isf
        }

        func getAllSettingsValues() async {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await self.getCurrentSettingValue(for: .basal)
                }
                group.addTask {
                    await self.getCurrentSettingValue(for: .carbRatio)
                }
                group.addTask {
                    await self.getCurrentSettingValue(for: .bgTarget)
                }
                group.addTask {
                    await self.getCurrentSettingValue(for: .isf)
                }
                group.addTask {
                    let getMaxBolus = await self.provider.getPumpSettings().maxBolus
                    await MainActor.run {
                        self.maxBolus = getMaxBolus
                    }
                }
                group.addTask {
                    let getPreferences = await self.provider.getPreferences()
                    await MainActor.run {
                        self.maxIOB = getPreferences.maxIOB
                        self.maxCOB = getPreferences.maxCOB
                    }
                }
            }
        }

        private func registerObservers() {
            broadcaster.register(DeterminationObserver.self, observer: self)
            broadcaster.register(BolusFailureObserver.self, observer: self)
        }

        @MainActor private func setupSettings() async {
            units = settingsManager.settings.units
            fraction = settings.settings.overrideFactor
            fattyMeals = settings.settings.fattyMeals
            fattyMealFactor = settings.settings.fattyMealFactor
            sweetMeals = settings.settings.sweetMeals
            sweetMealFactor = settings.settings.sweetMealFactor
            displayPresets = settings.settings.displayPresets
            confirmBolus = settings.settings.confirmBolus
            forecastDisplayType = settings.settings.forecastDisplayType
            lowGlucose = settingsManager.settings.low
            highGlucose = settingsManager.settings.high
            maxCarbs = settings.settings.maxCarbs
            maxFat = settings.settings.maxFat
            maxProtein = settings.settings.maxProtein
            useFPUconversion = settingsManager.settings.useFPUconversion
            isSmoothingEnabled = settingsManager.settings.smoothGlucose
            glucoseColorScheme = settingsManager.settings.glucoseColorScheme
        }

        private func getCurrentSettingValue(for type: SettingType) async {
            let now = Date()
            let calendar = Calendar.current
            let entries: [(start: String, value: Decimal)]

            switch type {
            case .basal:
                let basalEntries = await provider.getBasalProfile()
                entries = basalEntries.map { ($0.start, $0.rate) }
            case .carbRatio:
                let carbRatios = await provider.getCarbRatios()
                entries = carbRatios.schedule.map { ($0.start, $0.ratio) }
            case .bgTarget:
                let bgTargets = await provider.getBGTargets()
                entries = bgTargets.targets.map { ($0.start, $0.low) }
            case .isf:
                let isfValues = await provider.getISFValues()
                entries = isfValues.sensitivities.map { ($0.start, $0.sensitivity) }
            }

            for (index, entry) in entries.enumerated() {
                guard let entryTime = TherapySettingsUtil.parseTime(entry.start) else {
                    debug(.default, "Invalid entry start time: \(entry.start)")
                    continue
                }

                let entryComponents = calendar.dateComponents([.hour, .minute, .second], from: entryTime)
                let entryStartTime = calendar.date(
                    bySettingHour: entryComponents.hour!,
                    minute: entryComponents.minute!,
                    second: entryComponents.second ?? 0, // Set seconds to 0 if not provided
                    of: now
                )!

                let entryEndTime: Date
                if index < entries.count - 1 {
                    if let nextEntryTime = TherapySettingsUtil.parseTime(entries[index + 1].start) {
                        let nextEntryComponents = calendar.dateComponents([.hour, .minute, .second], from: nextEntryTime)
                        entryEndTime = calendar.date(
                            bySettingHour: nextEntryComponents.hour!,
                            minute: nextEntryComponents.minute!,
                            second: nextEntryComponents.second ?? 0,
                            of: now
                        )!
                    } else {
                        entryEndTime = calendar.date(byAdding: .day, value: 1, to: entryStartTime)!
                    }
                } else {
                    entryEndTime = calendar.date(byAdding: .day, value: 1, to: entryStartTime)!
                }

                if now >= entryStartTime, now < entryEndTime {
                    await MainActor.run {
                        switch type {
                        case .basal:
                            currentBasal = entry.value
                        case .carbRatio:
                            currentCarbRatio = entry.value
                        case .bgTarget:
                            currentBGTarget = entry.value
                        case .isf:
                            currentISF = entry.value
                        }
                    }
                    return
                }
            }
        }

        // MARK: CALCULATIONS FOR THE BOLUS CALCULATOR

        /// Calculate insulin recommendation
        func calculateInsulin() async -> Decimal {
            // Safely get minPredBG on main thread
            let localMinPredBG = await MainActor.run {
                minPredBG
            }

            // Use the cob value of the simulation if we have a simulated determination
            var simulatedCOB: Int16?
            if let simulatedCobValue = simulatedDetermination?.cob {
                // Convert Decimal to Int16 and cap at maxCOB
                let cobInt16 = Int16(truncating: NSDecimalNumber(decimal: simulatedCobValue))
                let maxCobInt16 = Int16(truncating: NSDecimalNumber(decimal: maxCOB))
                simulatedCOB = min(maxCobInt16, cobInt16)
            }

            // Check if this is a backdated entry by comparing with the default date using a tolerance
            let isBackdated = abs(date.timeIntervalSince(defaultDate)) > 1.0

            let result = await bolusCalculationManager.handleBolusCalculation(
                carbs: carbs,
                useFattyMealCorrection: useFattyMealCorrectionFactor,
                useSuperBolus: useSuperBolus,
                lastLoopDate: apsManager.lastLoopDate,
                minPredBG: localMinPredBG,
                simulatedCOB: simulatedCOB,
                isBackdated: isBackdated
            )

            // A superseded run must not overwrite the breakdown a newer run published.
            guard !Task.isCancelled else { return apsManager.roundBolus(amount: result.insulinCalculated) }

            // Update state properties with calculation results on main thread
            await MainActor.run {
                targetDifference = result.targetDifference
                targetDifferenceInsulin = result.targetDifferenceInsulin
                wholeCob = result.wholeCob
                wholeCobInsulin = result.wholeCobInsulin
                iobInsulinReduction = result.iobInsulinReduction
                superBolusInsulin = result.superBolusInsulin
                wholeCalc = result.wholeCalc
                factoredInsulin = result.factoredInsulin
                fifteenMinInsulin = result.fifteenMinutesInsulin
            }

            return apsManager.roundBolus(amount: result.insulinCalculated)
        }

        // MARK: - Button tasks

        func invokeTreatmentsTask() {
            Task {
                debug(.bolusState, "invokeTreatmentsTask fired")
                await MainActor.run {
                    self.addButtonPressed = true
                }
                let isInsulinGiven = amount > 0
                let isCarbsPresent = carbs > 0
                let isFatPresent = fat > 0
                let isProteinPresent = protein > 0

                if isCarbsPresent || isFatPresent || isProteinPresent {
                    await saveMeal()
                }

                if isInsulinGiven {
                    await handleInsulin(isExternal: externalInsulin)
                } else {
                    hideModal()
                    return
                }

                // If glucose data is stale end the custom loading animation by hiding the modal
                // Get date on Main thread
                let date = await MainActor.run {
                    glucoseFromPersistence.first?.date
                }

                guard glucoseStorage.isGlucoseDataFresh(date) else {
                    await MainActor.run {
                        isAwaitingDeterminationResult = false
                        showDeterminationFailureAlert = true
                        determinationFailureMessage = "Glucose data is stale"
                    }
                    return hideModal()
                }
            }
        }

        // MARK: - Insulin

        private func handleInsulin(isExternal: Bool) async {
            debug(.bolusState, "handleInsulin fired")

            if !isExternal {
                await addPumpInsulin()
            } else {
                await addExternalInsulin()
            }
        }

        /// Returns a user-facing localized error message for a given authentication error.
        ///
        /// This function inspects the provided `Error` to determine whether it is an `LAError`,
        /// and maps its error code to a human-readable, localized string describing the reason
        /// for the failure. If the error is not an `LAError`, a generic fallback message is returned.
        ///
        /// - Parameter error: The `Error` returned from an authentication attempt (e.g., via `LAContext.evaluatePolicy`).
        /// - Returns: A localized `String` describing the cause of the authentication failure.
        private func parseAuthenticationError(from error: Error) -> String {
            guard let laError = error as? LAError else {
                return String(
                    localized: "An unknown authentication error occurred. Please try again."
                )
            }

            switch laError.code {
            case .authenticationFailed:
                return String(
                    localized: "Authentication failed. Please try again."
                )

            case .userCancel:
                return String(
                    localized: "Authentication was canceled by you."
                )

            case .userFallback:
                return String(
                    localized: "You tapped the fallback option, but no fallback method is configured."
                )

            case .systemCancel:
                return String(
                    localized: "Authentication was canceled by the system. Try again."
                )

            case .appCancel:
                return String(
                    localized: "Authentication was canceled by the app."
                )

            case .invalidContext:
                return String(
                    localized: "Authentication context is invalid. Please try again."
                )

            case .notInteractive:
                return String(
                    localized: "Authentication UI cannot be displayed. Try restarting the app."
                )

            case .passcodeNotSet:
                return String(
                    localized: "Authentication requires a device passcode. Please set one in iOS Settings > Face ID & Passcode."
                )

            case .biometryNotAvailable:
                return String(
                    localized: "Biometric authentication is not available on this device."
                )

            case .biometryNotEnrolled:
                return String(
                    localized: "No biometric identities are enrolled. Please set up Face ID or Touch ID."
                )

            case .biometryLockout,
                 .touchIDLockout:
                return String(
                    localized: "Biometric authentication is locked due to multiple failed attempts. Please unlock your device using your passcode."
                )

            case .biometryDisconnected,
                 .biometryNotPaired:
                return String(
                    localized: "Biometric accessory is missing or not connected. Please reconnect it and try again."
                )

            default:
                return String(
                    localized: "An unknown biometric authentication error occurred. Please try again."
                )
            }
        }

        func addPumpInsulin() async {
            guard amount > 0 else {
                showModal(for: nil)
                return
            }

            let maxAmount = Double(min(amount, maxBolus))

            do {
                let authenticated = try await unlockmanager.unlock()
                if authenticated {
                    // show loading animation
                    await MainActor.run {
                        self.isAwaitingDeterminationResult = true
                    }
                    await apsManager.enactBolus(amount: maxAmount, isSMB: false, callback: nil)
                }
            } catch {
                debug(.bolusState, "Authentication error for pump bolus: \(error)")

                await MainActor.run {
                    self.isAwaitingDeterminationResult = false
                    self.showDeterminationFailureAlert = true
                    self.determinationFailureMessage = parseAuthenticationError(from: error)
                }
            }
        }

        // MARK: - EXTERNAL INSULIN

        func addExternalInsulin() async {
            guard amount > 0 else {
                showModal(for: nil)
                return
            }

            await MainActor.run {
                self.amount = min(self.amount, self.maxBolus * 3)
            }

            do {
                let authenticated = try await unlockmanager.unlock()
                if authenticated {
                    // show loading animation
                    await MainActor.run {
                        self.isAwaitingDeterminationResult = true
                    }
                    // store external dose to pump history
                    await pumpHistoryStorage.storeExternalInsulinEvent(amount: amount, timestamp: date)
                    // perform determine basal sync
                    try await apsManager.determineBasalSync()
                }
            } catch {
                debug(.bolusState, "authentication error for external insulin: \(error)")
                await MainActor.run {
                    self.isAwaitingDeterminationResult = false
                    self.showDeterminationFailureAlert = true
                    self.determinationFailureMessage = parseAuthenticationError(from: error)
                }
            }
        }

        // MARK: - Carbs

        func saveMeal() async {
            do {
                guard carbs > 0 || fat > 0 || protein > 0 else { return }

                await MainActor.run {
                    self.carbs = min(self.carbs, self.maxCarbs)
                    self.fat = min(self.fat, self.maxFat)
                    self.protein = min(self.protein, self.maxProtein)
                    self.id_ = UUID().uuidString
                }

                let carbsToStore = [CarbsEntry(
                    id: id_,
                    createdAt: now,
                    actualDate: date,
                    carbs: carbs,
                    fat: fat,
                    protein: protein,
                    note: note,
                    enteredBy: CarbsEntry.local,
                    isFPU: false,
                    fpuID: fat > 0 || protein > 0 ? UUID().uuidString : nil
                )]
                try await carbsStorage.storeCarbs(carbsToStore, areFetchedFromRemote: false)

                // only perform determine basal sync if the user doesn't use the pump bolus, otherwise the enact bolus func in the APSManger does a sync
                if amount <= 0 {
                    await MainActor.run {
                        self.isAwaitingDeterminationResult = true
                    }
                    try await apsManager.determineBasalSync()
                }
            } catch {
                debug(.default, "\(DebuggingIdentifiers.failed) Failed to save carbs: \(error)")
            }
        }

        // MARK: - AI-Assisted Food Analysis

        /// Analyzes a food image using AI. When the user has enabled "send to all providers
        /// simultaneously", the other providers are offered as tabs but only queried lazily
        /// when the user switches to them — we don't burn tokens on providers the user may
        /// never look at. Only the configured provider is queried up front.
        func analyzeFood(imageData: Data, description: String? = nil) async {
            let sendToAll = settingsManager.settings.sendToAllAIProvidersSimultaneously
            let configuredProvider = settingsManager.settings.aiProvider
            let tabs: [AIProviderType] = {
                if sendToAll {
                    let available = AIProviderType.allCases.filter(isProviderAvailable)
                    return available.isEmpty ? [configuredProvider] : available
                } else {
                    return [configuredProvider]
                }
            }()
            let initialProvider = tabs.contains(configuredProvider) ? configuredProvider : (tabs.first ?? configuredProvider)

            await MainActor.run {
                isAnalyzingFood = true
                aiError = nil
                foodItemSelection = nil
                conversationManager = nil
                premergeVisionItems = nil
                publishedRestaurantName = nil
                foodItemSelections.removeAll()
                conversationManagers.removeAll()
                perProviderErrors.removeAll()
                perProviderPremergeVisionItems.removeAll()
                perProviderPublishedRestaurantName.removeAll()
                // Only the initial provider is marked analyzing; other tabs stay dormant
                // and will be kicked off from `switchDisplayedProvider(to:)` on demand.
                perProviderAnalyzing = Dictionary(uniqueKeysWithValues: tabs.map { ($0, $0 == initialProvider) })
                activeProviders = tabs
                displayedProvider = initialProvider
                capturedImageData = imageData
                pendingImageData = imageData
                pendingAnalysisDescription = description
            }

            await runAnalysis(for: initialProvider, imageData: imageData, description: description)

            await MainActor.run {
                isAnalyzingFood = perProviderAnalyzing.values.contains(true)
            }
        }

        /// Runs a single provider's analysis and writes the result into its per-provider slot.
        /// If this provider is the currently-displayed one, the top-level `foodItemSelection`
        /// / `conversationManager` mirrors are also updated so the existing UI code keeps working.
        private func runAnalysis(
            for provider: AIProviderType,
            imageData: Data,
            description: String?
        ) async {
            let chatService = AIServiceRegistry.chat(for: provider)
            let responsesService = AIServiceRegistry.responses(for: provider)

            do {
                print("🍽️ [\(provider.displayName)] Starting food analysis. Description: \(description ?? "<none>")")

                let publishedNutritionTask: Task<PublishedNutritionResult?, Never> = Task {
                    guard let desc = description, !desc.isEmpty else {
                        return nil
                    }
                    do {
                        let classification = try await responsesService.classifyRestaurantItem(description: desc)
                        guard classification.isRestaurantItem,
                              !classification.restaurantName.isEmpty,
                              !classification.menuItemName.isEmpty
                        else {
                            return nil
                        }
                        let result = try await responsesService.searchPublishedNutrition(
                            restaurantName: classification.restaurantName,
                            menuItemName: classification.menuItemName
                        )
                        return result
                    } catch {
                        print("🍽️ [\(provider.displayName)] Classifier/search failed (non-fatal): \(error.localizedDescription)")
                        return nil
                    }
                }

                let stream = chatService.analyzeFoodStreaming(
                    imageData: imageData,
                    userDescription: description
                )

                let manager = AIConversationManager()
                manager.providerOverride = provider
                await MainActor.run {
                    conversationManagers[provider] = manager
                    if displayedProvider == provider {
                        conversationManager = manager
                    }
                }

                let visionResponse = try await manager.initializeStreaming(
                    stream: stream,
                    imageData: imageData,
                    userDescription: description,
                    onItemsUpdated: { [weak self] items in
                        guard let self else { return }
                        let response = AIFoodItemsResponse(
                            foodItems: items,
                            overallConfidence: 0
                        )
                        let selection = FoodItemSelection(response: response)
                        self.foodItemSelections[provider] = selection
                        if self.displayedProvider == provider {
                            self.foodItemSelection = selection
                        }
                    }
                )

                let publishedResult = await publishedNutritionTask.value

                await MainActor.run {
                    perProviderPremergeVisionItems[provider] = visionResponse.foodItems
                    perProviderPublishedRestaurantName[provider] = publishedResult?.restaurantName
                    if displayedProvider == provider {
                        premergeVisionItems = visionResponse.foodItems
                        publishedRestaurantName = publishedResult?.restaurantName
                    }
                }

                let mergedItems = NutritionFactsMerger.merge(
                    publishedResult: publishedResult,
                    visionItems: visionResponse.foodItems
                )

                await MainActor.run {
                    let mergedResponse = AIFoodItemsResponse(
                        foodItems: mergedItems,
                        overallConfidence: visionResponse.overallConfidence
                    )

                    if mergedItems != visionResponse.foodItems {
                        manager.replaceItems(
                            mergedItems,
                            restaurantName: publishedResult?.restaurantName,
                            sourceURL: publishedResult?.sourceURL
                        )
                    }

                    let selection = FoodItemSelection(response: mergedResponse)
                    foodItemSelections[provider] = selection
                    perProviderAnalyzing[provider] = false

                    if displayedProvider == provider {
                        // No withAnimation here — an animated swap of foodItemSelection
                        // cascades a layout animation into the provider tab bar above
                        // and makes the tabs slide vertically on completion.
                        foodItemSelection = selection
                        updateFormFromSelection()
                    }
                    print("🍽️ [\(provider.displayName)] Analysis complete")
                }
            } catch {
                await MainActor.run {
                    perProviderAnalyzing[provider] = false
                    let message = providerFacingErrorMessage(for: error, provider: provider)
                    perProviderErrors[provider] = message
                    // Only surface errors for the provider the user is currently looking at —
                    // a background/dormant provider failing silently shouldn't pop an alert.
                    if displayedProvider == provider, foodItemSelection == nil {
                        aiError = message
                    }
                }
            }
        }

        /// Maps a provider error into a user-facing string. Surfaces a clear "out of credits"
        /// message when the response body matched one of the known billing signals
        /// (OpenAI: 429 + `insufficient_quota`; Anthropic: 400 + `insufficient_balance_error`).
        /// For generic HTTP failures we prefix the provider name so the user knows which one failed.
        private func providerFacingErrorMessage(for error: Error, provider: AIProviderType) -> String {
            if case OpenAIServiceError.insufficientCredits = error {
                return String(
                    format: String(
                        localized: "%@ is out of credits. Please top up your account before analyzing more images.",
                        comment: "Alert shown when a provider responds with an out-of-credits signal"
                    ),
                    provider.displayName
                )
            }
            if case let OpenAIServiceError.invalidResponse(statusCode) = error {
                switch statusCode {
                case 401,
                     403:
                    return String(
                        format: String(
                            localized: "%@ rejected the API key (status %d). Check the key configured in ConfigOverride.xcconfig.",
                            comment: "Alert shown when a provider returns HTTP 401/403"
                        ),
                        provider.displayName, statusCode
                    )
                case 429:
                    return String(
                        format: String(
                            localized: "%@ is currently rate-limiting requests. Please try again in a moment.",
                            comment: "Alert shown when a provider returns HTTP 429 without an insufficient_quota code"
                        ),
                        provider.displayName
                    )
                default:
                    return "\(provider.displayName): \(error.localizedDescription)"
                }
            }
            return "\(provider.displayName): \(error.localizedDescription)"
        }

        /// Switches which provider's results are displayed in the food item list + form.
        /// Mirrors the provider's per-provider slot into the top-level `foodItemSelection` /
        /// `conversationManager` and recomputes the bolus form from the new selection.
        /// If the target provider hasn't been queried yet (lazy multi-provider mode), this
        /// kicks off its analysis now.
        @MainActor func switchDisplayedProvider(to provider: AIProviderType) {
            guard displayedProvider != provider else { return }
            // Disable animations at the source so SwiftUI/Form doesn't attach
            // an ambient transition (slide/opacity) to the resulting view-tree
            // diff. Tab switches must be visually instantaneous — including the
            // form-field updates triggered by `updateFormFromSelection`, since
            // they share the same Section as the tab bar and a List row-height
            // change there will pull the tab bar with it.
            var txn = Transaction()
            txn.disablesAnimations = true

            withTransaction(txn) {
                displayedProvider = provider
                foodItemSelection = foodItemSelections[provider]
                conversationManager = conversationManagers[provider]
                premergeVisionItems = perProviderPremergeVisionItems[provider]
                publishedRestaurantName = perProviderPublishedRestaurantName[provider]
            }

            if foodItemSelection != nil {
                withTransaction(txn) {
                    updateFormFromSelection()
                }
                return
            }

            // Lazy-query: if this tab has never been analyzed, kick it off now.
            let hasBeenQueried = perProviderAnalyzing[provider] == true ||
                perProviderErrors[provider] != nil
            guard !hasBeenQueried, let imageData = pendingImageData else { return }

            withTransaction(txn) {
                perProviderAnalyzing[provider] = true
                isAnalyzingFood = true
                aiError = nil
            }

            let description = pendingAnalysisDescription
            Task { [weak self] in
                await self?.runAnalysis(for: provider, imageData: imageData, description: description)
                await MainActor.run {
                    guard let self else { return }
                    var endTxn = Transaction()
                    endTxn.disablesAnimations = true
                    withTransaction(endTxn) {
                        self.isAnalyzingFood = self.perProviderAnalyzing.values.contains(true)
                    }
                }
            }
        }

        /// Shared helper: applies a food item selection to the form fields, metadata, and triggers recalculation
        @MainActor private func applySelection(_ selection: FoodItemSelection, userModified: Bool) {
            carbs = Decimal(selection.selectedCarbs)
            note = selection.collapsedSummary

            let itemDescriptions = selection.response.foodItems.map { item in
                let emoji = item.emoji ?? ""
                return "\(emoji) \(item.name): \(Int(item.carbs))g"
            }.joined(separator: ", ")

            fat = Decimal(selection.selectedFat)
            protein = Decimal(selection.selectedProtein)

            aiAssistedMetadata = AIAssistedCarbEntryMetadata(
                detailedDescription: itemDescriptions,
                estimatedCarbs: selection.response.totalCarbs,
                emoji: selection.mainItem?.emoji ?? "",
                fat: selection.selectedFat,
                protein: selection.selectedProtein,
                carbConfidence: selection.response.overallConfidence,
                emojiConfidence: selection.response.overallConfidence,
                userModified: userModified,
                foodItems: selection.response.foodItems,
                selectedItemIds: Array(selection.selectedItemIds)
            )

            Task { @MainActor in
                await updateForecasts()
                insulinCalculated = await calculateInsulin()
                amount = insulinCalculated
            }
        }

        /// Updates form fields based on current food item selection
        @MainActor func updateFormFromSelection() {
            guard let selection = foodItemSelection else { return }

            if originalAICarbsQuantity == nil {
                originalAICarbsQuantity = selection.response.totalCarbs
            }

            applySelection(selection, userModified: selection.userModifiedSelection)
        }

        /// Update the user's serving count for a specific item and recalculate form values
        @MainActor func updateServingCount(for itemId: UUID, count: Double) {
            guard foodItemSelection != nil else { return }
            foodItemSelection?.userServingCounts[itemId] = count
            if let provider = displayedProvider, let updated = foodItemSelection {
                foodItemSelections[provider] = updated
            }
            updateFormFromSelection()
        }

        /// Toggle selection of a food item and update form
        @MainActor func toggleFoodItem(_ itemId: UUID) {
            guard foodItemSelection != nil else { return }
            foodItemSelection?.toggleSelection(for: itemId)
            conversationManager?.toggleSelection(for: itemId)
            if let provider = displayedProvider, let updated = foodItemSelection {
                foodItemSelections[provider] = updated
            }
            updateFormFromSelection()
        }

        /// Accepts published nutrition for an item (no-op — values are already applied)
        @MainActor func acceptPublishedNutrition(for _: UUID) {
            // Nothing to do — published values are already in use
        }

        /// Rejects published nutrition for an item and restores the original vision estimate
        @MainActor func rejectPublishedNutrition(for itemId: UUID) {
            guard var selection = foodItemSelection else { return }

            let currentItems = selection.response.foodItems

            // Find the published item being rejected
            guard let publishedItem = currentItems.first(where: { $0.id == itemId && $0.source == .published }) else {
                return
            }

            // Find matching vision item(s) from the pre-merge snapshot
            let restaurantName = publishedRestaurantName ?? ""
            let fallbackItems: [AIFoodItem]
            if let visionItems = premergeVisionItems {
                fallbackItems = visionItems.filter { visionItem in
                    NutritionFactsMerger.isLikelyMatch(
                        visionItemName: visionItem.name,
                        publishedItemName: publishedItem.name,
                        restaurantName: restaurantName
                    )
                }
            } else {
                fallbackItems = []
            }

            // Build the new items list: replace the published item with vision fallback(s)
            var newItems: [AIFoodItem] = []
            for item in currentItems {
                if item.id == itemId {
                    if fallbackItems.isEmpty {
                        // No vision fallback found — keep the published item but mark as estimated
                        newItems.append(AIFoodItem(
                            name: publishedItem.name,
                            carbs: publishedItem.carbs,
                            emoji: publishedItem.emoji,
                            fat: publishedItem.fat,
                            protein: publishedItem.protein,
                            source: .estimated
                        ))
                    } else {
                        newItems.append(contentsOf: fallbackItems)
                    }
                } else {
                    newItems.append(item)
                }
            }

            let newResponse = AIFoodItemsResponse(
                foodItems: newItems,
                overallConfidence: selection.response.overallConfidence
            )
            var newSelection = FoodItemSelection(response: newResponse)
            newSelection.userServingCounts = selection.userServingCounts

            withAnimation(.easeInOut(duration: 0.35)) {
                foodItemSelection = newSelection
            }
            if let provider = displayedProvider {
                foodItemSelections[provider] = newSelection
            }

            conversationManager?.replaceItems(newItems)
            updateFormFromSelection()
        }

        /// Clears the AI error state
        func clearAIError() {
            aiError = nil
        }

        /// Clears the food item selection (resets AI analysis)
        func clearFoodItemSelection() {
            foodItemSelection = nil
            conversationManager = nil
            capturedImageData = nil
            foodDescription = ""
            originalAICarbsQuantity = nil
            aiAssistedMetadata = nil
            pendingImageData = nil
            premergeVisionItems = nil
            publishedRestaurantName = nil
            foodItemSelections.removeAll()
            conversationManagers.removeAll()
            perProviderAnalyzing.removeAll()
            perProviderErrors.removeAll()
            perProviderPremergeVisionItems.removeAll()
            perProviderPublishedRestaurantName.removeAll()
            activeProviders.removeAll()
            displayedProvider = nil
        }

        /// Edit a food item's description and recalculate its carbs
        func editFoodItemDescription(_ itemId: UUID, newDescription: String) async {
            guard let manager = conversationManager else { return }

            // Immediately update the item name in the selection so the UI doesn't revert
            await MainActor.run {
                if var selection = foodItemSelection,
                   let index = selection.response.foodItems.firstIndex(where: { $0.id == itemId })
                {
                    let oldItem = selection.response.foodItems[index]
                    var updatedItems = selection.response.foodItems
                    updatedItems[index] = AIFoodItem(
                        id: oldItem.id,
                        name: newDescription,
                        carbs: oldItem.carbs,
                        emoji: oldItem.emoji,
                        fat: oldItem.fat,
                        protein: oldItem.protein,
                        servingCount: oldItem.servingCount,
                        servingUnit: oldItem.servingUnit
                    )
                    let updatedResponse = AIFoodItemsResponse(
                        foodItems: updatedItems,
                        overallConfidence: selection.response.overallConfidence
                    )
                    var newSelection = FoodItemSelection(response: updatedResponse)
                    newSelection.selectedItemIds = selection.selectedItemIds
                    newSelection.userServingCounts = selection.userServingCounts
                    foodItemSelection = newSelection
                    if let provider = displayedProvider {
                        foodItemSelections[provider] = newSelection
                    }
                }
            }

            await manager.updateItemDescription(itemId: itemId, newDescription: newDescription)

            // Update form with the final carb values from the API
            await MainActor.run {
                updateFormFromConversation()
            }
        }

        /// Updates form fields from the conversation manager's current state
        @MainActor func updateFormFromConversation() {
            guard let manager = conversationManager else { return }

            let response = AIFoodItemsResponse(
                foodItems: manager.currentItems,
                overallConfidence: manager.overallConfidence
            )
            var selection = FoodItemSelection(response: response)
            selection.selectedItemIds = manager.selectedItemIds
            // Preserve user's per-item serving counts
            if let oldCounts = foodItemSelection?.userServingCounts {
                for (id, count) in oldCounts {
                    selection.userServingCounts[id] = count
                }
            }
            foodItemSelection = selection
            if let provider = displayedProvider {
                foodItemSelections[provider] = selection
            }

            applySelection(selection, userModified: true)
        }

        /// Accept values from the conversation manager (called when user taps Accept in chat)
        @MainActor func acceptConversationValues(_ selection: FoodItemSelection) {
            foodItemSelection = selection
            if let provider = displayedProvider {
                foodItemSelections[provider] = selection
            }
            conversationManager?.selectedItemIds = selection.selectedItemIds
            applySelection(selection, userModified: true)
        }

        /// Get the IDs of items currently being recalculated (for shimmer animation)
        var pendingItemIds: Set<UUID> {
            conversationManager?.pendingItemIds ?? []
        }

        // MARK: - Presets

        func deletePreset() {
            if selection != nil {
                viewContext.delete(selection!)

                do {
                    guard viewContext.hasChanges else { return }
                    try viewContext.save()
                } catch {
                    print(error.localizedDescription)
                }
                carbs = 0
                fat = 0
                protein = 0
            }
            selection = nil
        }

        func removePresetFromNewMeal() {
            let a = summation.firstIndex(where: { $0 == selection?.dish! })
            if a != nil, summation[a ?? 0] != "" {
                summation.remove(at: a!)
            }
        }

        func addPresetToNewMeal() {
            if let selection = selection, let dish = selection.dish {
                summation.append(dish)
            }
        }

        func addNewPresetToWaitersNotepad(_ dish: String) {
            summation.append(dish)
        }

        func addToSummation() {
            summation.append(selection?.dish ?? "")
        }
    }
}

extension Treatments.StateModel: DeterminationObserver, BolusFailureObserver {
    func determinationDidUpdate(_: Determination) {
        guard isActive else {
            debug(.bolusState, "skipping determinationDidUpdate; view not active")
            return
        }

        DispatchQueue.main.async {
            debug(.bolusState, "determinationDidUpdate fired")
            self.isAwaitingDeterminationResult = false
            if self.addButtonPressed {
                self.hideModal()
            }
        }
    }

    func bolusDidFail() {
        DispatchQueue.main.async {
            // A dismissed instance may still observe until dealloc — don't hide an unrelated modal.
            guard self.isActive else { return }
            debug(.bolusState, "bolusDidFail fired")
            self.isAwaitingDeterminationResult = false
            if self.addButtonPressed {
                self.hideModal()
            }
        }
    }
}

// MARK: - Setup Glucose, Determinations and Last Bolus

extension Treatments.StateModel {
    // MARK: - Glucose Controller

    @MainActor func setupGlucoseController() {
        glucoseControllerDelegate.onContentChange = { [weak self] in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                self.updateGlucoseFromController()
            }
        }

        do {
            try glucoseController.performFetch()
            updateGlucoseFromController()
        } catch {
            debug(.default, "\(DebuggingIdentifiers.failed) Failed to perform glucose fetch: \(error)")
        }
    }

    @MainActor private func updateGlucoseFromController() {
        guard let objects = glucoseController.fetchedObjects else { return }

        // Store all objects for the forecast graph
        glucoseFromPersistence = objects

        // Always use the most recent reading for current glucose
        let lastGlucose = objects.first?.glucose ?? 0

        // Filter for readings less than 20 minutes old
        let twentyMinutesAgo = Date().addingTimeInterval(-20 * 60)
        let recentObjects = objects.filter {
            guard let date = $0.date else { return false }
            return date > twentyMinutesAgo
        }

        // Calculate delta using newest and oldest readings within 20-minute window
        let delta: Decimal
        if let newestInWindow = recentObjects.first?.glucose, let oldestInWindow = recentObjects.last?.glucose {
            // Newest is at index 0, oldest is at the last index
            delta = Decimal(newestInWindow) - Decimal(oldestInWindow)
        } else {
            // Not enough data points in the window
            delta = 0
        }

        currentBG = Decimal(lastGlucose)
        deltaBG = delta
    }

    // MARK: - Determination Controller

    @MainActor func setupDeterminationController() {
        determinationControllerDelegate.onContentChange = { [weak self] in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                self.updateDeterminationFromController()
                self.scheduleInsulinAndForecastUpdate()
            }
        }

        do {
            try determinationController.performFetch()
            updateDeterminationFromController()
            scheduleInsulinAndForecastUpdate()
        } catch {
            debug(.default, "\(DebuggingIdentifiers.failed) Failed to perform determination fetch: \(error)")
        }
    }

    /// Recomputes bolus recommendation and forecast; each new determination cancels the
    /// previous in-flight run so a superseded run cannot publish stale results.
    @MainActor private func scheduleInsulinAndForecastUpdate() {
        determinationUpdateTask?.cancel()
        determinationUpdateTask = Task { @MainActor in
            let insulinCalculated = await self.calculateInsulin()
            guard !Task.isCancelled else { return }
            self.insulinCalculated = insulinCalculated
            self.amount = insulinCalculated
            let forecastData = self.mapForecastsFromController()
            await self.updateForecasts(with: forecastData)
        }
    }

    @MainActor private func updateDeterminationFromController() {
        guard let objects = determinationController.fetchedObjects,
              let mostRecentDetermination = objects.first else { return }

        determination = objects

        // setup vars for bolus calculation
        insulinRequired = (mostRecentDetermination.insulinReq ?? 0) as Decimal
        evBG = (mostRecentDetermination.eventualBG ?? 0) as Decimal
        minPredBG = (mostRecentDetermination.minPredBGFromReason ?? 0) as Decimal
        lastLoopDate = apsManager.lastLoopDate as Date?
        insulin = (mostRecentDetermination.insulinForManualBolus ?? 0) as Decimal
        target = (mostRecentDetermination.currentTarget ?? currentBGTarget as NSDecimalNumber) as Decimal
        isf = (mostRecentDetermination.insulinSensitivity ?? currentISF as NSDecimalNumber) as Decimal
        cob = mostRecentDetermination.cob as Int16
        iob = (mostRecentDetermination.iob ?? 0) as Decimal
        basal = (mostRecentDetermination.tempBasal ?? 0) as Decimal
        carbRatio = (mostRecentDetermination.carbRatio ?? currentCarbRatio as NSDecimalNumber) as Decimal
    }

    @MainActor private func mapForecastsFromController() -> Determination? {
        guard let determinationObject = determinationController.fetchedObjects?.first else {
            return nil
        }

        let forecastsSet = determinationObject.forecasts ?? []
        let predictions = Predictions(
            iob: forecastsSet.extractValues(for: "iob"),
            zt: forecastsSet.extractValues(for: "zt"),
            cob: forecastsSet.extractValues(for: "cob"),
            uam: forecastsSet.extractValues(for: "uam")
        )

        return Determination(
            id: UUID(),
            reason: "",
            units: 0,
            insulinReq: 0,
            sensitivityRatio: 0,
            rate: 0,
            duration: 0,
            iob: 0,
            cob: 0,
            predictions: predictions.isEmpty ? nil : predictions,
            carbsReq: 0,
            temp: nil,
            reservoir: 0,
            carbRatio: 0,
            received: false
        )
    }
}

extension Treatments.StateModel {
    @MainActor func updateForecasts(with forecastData: Determination? = nil) async {
        guard isActive else {
            return
                debug(.bolusState, "updateForecasts not fired")
        }

        debug(.bolusState, "updateForecasts fired")
        if let forecastData = forecastData {
            simulatedDetermination = forecastData
            debugPrint("\(DebuggingIdentifiers.failed) minPredBG: \(minPredBG)")
        } else {
            let simulated = await Task { [self] in
                debug(.bolusState, "calling simulateDetermineBasal to get forecast data")
                return await apsManager.simulateDetermineBasal(
                    simulatedCarbsAmount: carbs,
                    simulatedBolusAmount: amount,
                    simulatedCarbsDate: date
                )
            }.value

            // Stale minPredBG/cob from a superseded run would feed the next bolus calculation.
            guard !Task.isCancelled else { return }
            simulatedDetermination = simulated

            // Update evBG and minPredBG from simulated determination
            if let simDetermination = simulated {
                evBG = Decimal(simDetermination.eventualBG ?? 0)
                minPredBG = simDetermination.minPredBGFromReason ?? 0
                debugPrint("\(DebuggingIdentifiers.inProgress) minPredBG: \(minPredBG)")
            }
        }

        predictionsForChart = simulatedDetermination?.predictions

        let nonEmptyArrays = [
            predictionsForChart?.iob,
            predictionsForChart?.zt,
            predictionsForChart?.cob,
            predictionsForChart?.uam
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }

        guard !nonEmptyArrays.isEmpty else {
            minForecast = []
            maxForecast = []
            return
        }

        minCount = max(12, nonEmptyArrays.map(\.count).min() ?? 0)
        guard minCount > 0 else { return }

        async let minForecastResult = Task {
            await (0 ..< self.minCount).map { index in
                nonEmptyArrays.compactMap { $0.indices.contains(index) ? $0[index] : nil }.min() ?? 0
            }
        }.value

        async let maxForecastResult = Task {
            await (0 ..< self.minCount).map { index in
                nonEmptyArrays.compactMap { $0.indices.contains(index) ? $0[index] : nil }.max() ?? 0
            }
        }.value

        let minResult = await minForecastResult
        let maxResult = await maxForecastResult

        guard !Task.isCancelled else { return }

        minForecast = minResult
        maxForecast = maxResult
    }
}

private extension Predictions {
    var isEmpty: Bool {
        iob == nil && zt == nil && cob == nil && uam == nil
    }
}

// MARK: - Last Pump Bolus

extension Treatments.StateModel {
    /// Mirrors `HomeStateModel`'s last-bolus controller so the in-progress visualizer can show the
    /// running pump-bolus's amount as the denominator (not the user's pending entry).
    /// Filters out external boluses via `NSPredicate.lastPumpBolus`.
    @MainActor func setupLastBolusController() {
        lastBolusControllerDelegate.onContentChange = { [weak self] in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                self.updateLastBolusFromController()
            }
        }

        do {
            try lastBolusController.performFetch()
            updateLastBolusFromController()
        } catch {
            debug(.default, "\(DebuggingIdentifiers.failed) Failed to perform last bolus fetch: \(error)")
        }
    }

    @MainActor private func updateLastBolusFromController() {
        lastPumpBolus = lastBolusController.fetchedObjects?.first
    }
}

private extension Set where Element == Forecast {
    /// Extracts the sorted forecast values for a given prediction type (iob/zt/cob/uam).
    func extractValues(for type: String) -> [Int]? {
        let values = first { $0.type == type }?
            .forecastValuesArray
            .map { Int($0.value) }
        return (values?.isEmpty ?? true) ? nil : values
    }
}
