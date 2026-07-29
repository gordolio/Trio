import SwiftUI

/// Self-contained view for AI-assisted food analysis.
/// Manages its own state for photo capture, description input, analysis, and item selection.
/// Communicates results back via the `onApplyCarbs` callback.
struct AIFoodAnalysisView: View {
    @Bindable var state: Treatments.StateModel
    let onOpenChat: () -> Void

    @State private var showPhotoSourcePicker = false
    @State private var showPhotoPicker = false
    @State private var photoSourceType: PhotoSourceType = .photoLibrary
    @State private var selectedImage: UIImage?
    @State private var isFoodItemsExpanded = false

    private var isDisplayedModelAnalyzing: Bool {
        guard let modelID = state.displayedProvider else { return state.isAnalyzingFood }
        return state.perProviderAnalyzing[modelID] == true
    }

    var body: some View {
        Group {
            if !state.isInAIMode {
                // AI button
                AnimatedRainbowButton(
                    title: NSLocalizedString("Analyze Food with AI", comment: "Button label for AI-assisted food analysis"),
                    icon: "sparkles",
                    isLoading: state.isAnalyzingFood,
                    action: { showPhotoSourcePicker = true }
                )
                .padding(.bottom, 4)
            } else if state.foodItemSelection == nil, state.foodItemSelections.isEmpty, state.activeProviders.isEmpty,
                      let imageData = state.capturedImageData
            {
                // Keep the description form visible while the real primary analysis
                // runs in the background and shows provisional nutrition below it.
                ZStack {
                    FoodDescriptionInputView(
                        description: Binding(
                            get: { state.foodDescription },
                            set: { state.updateFoodDescription($0) }
                        ),
                        imageData: imageData,
                        isPreparingAnalysis: state.isPreparingFoodAnalysis,
                        provisionalItems: state.provisionalFoodItems,
                        provisionalError: state.provisionalFoodAnalysisError,
                        onContinue: {
                            state.isAnalyzingFood = true
                            state.startFoodAnalysis(
                                imageData: imageData,
                                description: state.foodDescription.isEmpty ? nil : state.foodDescription
                            )
                        },
                        onCancel: {
                            guard !state.isAnalyzingFood else { return }
                            withAnimation(.easeInOut(duration: 0.35)) {
                                state.cancelCapturedImagePreparation()
                            }
                        }
                    )
                    .disabled(state.isAnalyzingFood)
                    .opacity(state.isAnalyzingFood ? 0.4 : 1.0)

                    if state.isAnalyzingFood {
                        analysisOverlay
                    }
                }
            } else if state.foodItemSelection != nil || !state.foodItemSelections.isEmpty || !state.activeProviders.isEmpty {
                // Food items selection tree (shown during streaming and after completion)
                VStack(spacing: 0) {
                    FoodItemsSelectionView(
                        selection: $state.foodItemSelection,
                        isExpanded: $isFoodItemsExpanded,
                        pendingItemIds: state.pendingItemIds,
                        providerTabs: state.activeProviders.map { provider in
                                FoodProviderTab(
                                    provider: provider,
                                    isAnalyzing: state.perProviderAnalyzing[provider] ?? false,
                                    error: state.perProviderErrors[provider]
                                )
                            },
                        selectedProvider: state.displayedProvider,
                        onSelectProvider: { provider in
                            state.switchDisplayedProvider(to: provider)
                        },
                        onRetryProvider: { provider in state.retryAnalysis(for: provider) },
                        onToggleItem: { itemId in
                            state.toggleFoodItem(itemId)
                        },
                        onEditItem: isDisplayedModelAnalyzing ? nil : { itemId, newDescription in
                            Task {
                                await state.editFoodItemDescription(itemId, newDescription: newDescription)
                            }
                        },
                        onOpenChat: isDisplayedModelAnalyzing ? nil : onOpenChat,
                        onAcceptPublished: { itemId in
                            state.acceptPublishedNutrition(for: itemId)
                        },
                        onRejectPublished: { itemId in
                            state.rejectPublishedNutrition(for: itemId)
                        }
                    )

                    if let selection = state.foodItemSelection, !isDisplayedModelAnalyzing {
                        ForEach(selection.selectedItems) { item in
                            ServingPickerView(
                                item: item,
                                userCount: Binding(
                                    get: { state.foodItemSelection?.userServingCounts[item.id] ?? item.servingCount },
                                    set: { state.updateServingCount(for: item.id, count: $0) }
                                )
                            )
                        }
                        .padding(.top, 6)
                    }

                    if isDisplayedModelAnalyzing {
                        HStack(spacing: 6) {
                            AnimatedSparkleIcon(isAnimating: true)
                            Text("Analyzing\u{2026}")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                // Strip any ambient animation cascading into this subtree (Form's
                // implicit animations, parent .animation modifiers, etc.) so that
                // switching provider tabs doesn't slide the tab bar around.
                // Internal animations (shimmer, sparkle, expand toggle) start their
                // own transactions and are unaffected.
                .transaction { $0.animation = nil }
                .onChange(of: state.foodItemSelection?.response.foodItems.count) { _, _ in
                    // Auto-expand when first items stream in
                    if state.isAnalyzingFood, !isFoodItemsExpanded {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isFoodItemsExpanded = true
                        }
                    }
                }
            }
        }
        .actionSheet(isPresented: $showPhotoSourcePicker) {
            ActionSheet(
                title: Text("Select Photo Source"),
                buttons: [
                    .default(Text("Camera")) {
                        photoSourceType = .camera
                        showPhotoPicker = true
                    },
                    .default(Text("Photo Library")) {
                        photoSourceType = .photoLibrary
                        showPhotoPicker = true
                    },
                    .cancel()
                ]
            )
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPickerWrapper(
                selectedImage: $selectedImage,
                isPresented: $showPhotoPicker,
                sourceType: photoSourceType
            )
        }
        .onChange(of: selectedImage) { _, newImage in
            if let image = newImage,
               let imageData = image.compressedForAI()
            {
                withAnimation(.easeInOut(duration: 0.35)) {
                    state.prepareCapturedImage(imageData)
                }
                selectedImage = nil
            }
        }
        .onAppear {
            // Check if the ScanFood shortcut captured an image for us
            if let imageData = ScanFoodImageRelay.shared.pendingImageData {
                ScanFoodImageRelay.shared.pendingImageData = nil
                withAnimation(.easeInOut(duration: 0.35)) {
                    state.prepareCapturedImage(imageData)
                }
            }
        }
        .alert(
            Text("AI Analysis Error"),
            isPresented: Binding(
                get: { state.aiError != nil },
                set: { if !$0 { state.clearAIError() } }
            ),
            actions: {
                Button("OK") {
                    state.clearAIError()
                }
            },
            message: {
                Text(state.aiError ?? "")
            }
        )
    }

    private var analysisOverlay: some View {
        VStack(spacing: 8) {
            AnimatedSparkleIcon(isAnimating: true)
                .scaleEffect(1.5)

            Text("Analyzing\u{2026}")
                .font(.caption.bold())
                .foregroundColor(Color(hue: 0.75, saturation: 0.6, brightness: 0.8))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemBackground).opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.clear)
                .totalShimmer(isAnimating: true)
        )
    }
}
