import LoopKitUI
import SwiftUI

// MARK: - Nutrient Display Mode

/// Which nutrient value to show in the food items list
enum NutrientDisplayMode: CaseIterable {
    case carbs
    case fat
    case protein

    var label: String {
        switch self {
        case .carbs: return String(localized: "carbs", comment: "Nutrient label for carbohydrates")
        case .fat: return String(localized: "fat", comment: "Nutrient label for fat")
        case .protein: return String(localized: "protein", comment: "Nutrient label for protein")
        }
    }

    var next: NutrientDisplayMode {
        let all = Self.allCases
        let idx = all.firstIndex(of: self)!
        return all[(idx + 1) % all.count]
    }
}

/// Metadata for a single provider tab shown above the food items list in multi-provider
/// comparison mode. Passing an empty array hides the tab bar entirely.
struct FoodProviderTab: Identifiable, Equatable {
    let provider: String
    let isAnalyzing: Bool
    let error: String?
    var id: String { provider }
}

/// A collapsible view for displaying and selecting individual food items from AI analysis
/// Now supports inline editing of item descriptions and shimmer animations during recalculation
struct FoodItemsSelectionView: View {
    @Binding var selection: FoodItemSelection?
    @Binding var isExpanded: Bool

    /// IDs of items currently being recalculated (shows shimmer animation)
    let pendingItemIds: Set<UUID>

    /// Provider tabs shown above the header. Empty = single-provider mode, no tab bar.
    let providerTabs: [FoodProviderTab]

    /// The currently-selected provider tab. Ignored when `providerTabs` is empty.
    let selectedProvider: String?

    /// Called when user taps a provider tab
    let onSelectProvider: ((String) -> Void)?
    let onRetryProvider: ((String) -> Void)?

    /// Called when user toggles an item's checkbox
    let onToggleItem: (UUID) -> Void

    /// Called when user edits an item's description (itemId, newDescription)
    let onEditItem: ((UUID, String) -> Void)?

    /// Called when user taps "Refine with AI" button
    let onOpenChat: (() -> Void)?

    /// Called when user accepts published nutrition for an item
    let onAcceptPublished: ((UUID) -> Void)?

    /// Called when user rejects published nutrition for an item
    let onRejectPublished: ((UUID) -> Void)?

    // State for inline editing
    @State private var editingItemId: UUID?
    @State private var editText: String = ""
    @FocusState private var isEditingFocused: Bool

    // State for nutrient display cycling
    @State private var nutrientDisplay: NutrientDisplayMode = .carbs

    // Check if any item is pending (for total shimmer)
    private var isAnyItemPending: Bool {
        !pendingItemIds.isEmpty
    }

    init(
        selection: Binding<FoodItemSelection?>,
        isExpanded: Binding<Bool>,
        pendingItemIds: Set<UUID> = [],
        providerTabs: [FoodProviderTab] = [],
        selectedProvider: String? = nil,
        onSelectProvider: ((String) -> Void)? = nil,
        onRetryProvider: ((String) -> Void)? = nil,
        onToggleItem: @escaping (UUID) -> Void,
        onEditItem: ((UUID, String) -> Void)? = nil,
        onOpenChat: (() -> Void)? = nil,
        onAcceptPublished: ((UUID) -> Void)? = nil,
        onRejectPublished: ((UUID) -> Void)? = nil
    ) {
        _selection = selection
        _isExpanded = isExpanded
        self.pendingItemIds = pendingItemIds
        self.providerTabs = providerTabs
        self.selectedProvider = selectedProvider
        self.onSelectProvider = onSelectProvider
        self.onRetryProvider = onRetryProvider
        self.onToggleItem = onToggleItem
        self.onEditItem = onEditItem
        self.onOpenChat = onOpenChat
        self.onAcceptPublished = onAcceptPublished
        self.onRejectPublished = onRejectPublished
    }

    var body: some View {
        // Keep a single outer VStack so `providerTabBar` retains a stable view
        // identity when the selected provider flips between having results and
        // being a lazy placeholder — otherwise the tab bar gets re-inserted on
        // every switch and the ambient animation slides the tabs around.
        if selection != nil || !providerTabs.isEmpty {
            VStack(spacing: 0) {
                if providerTabs.count > 1 {
                    providerTabBar
                }

                if let selection {
                    collapsedHeader(selection: selection)

                    if isExpanded {
                        expandedContent(selection: selection)

                        if onOpenChat != nil {
                            refineWithAIButton
                        }
                    }
                } else {
                    loadingPlaceholder
                }
            }
            // Strip ambient animations cascading in from the parent (e.g. the
            // Treatments form's implicit layout animations, or withAnimation
            // wrappers in TreatmentsStateModel) so they don't slide the tab
            // bar around when the inner content swaps. Internal withAnimation
            // calls (shimmer, sparkle, expand toggle) create their own
            // transactions and survive this.
            .transaction { $0.animation = nil }
        }
    }

    private var loadingPlaceholder: some View {
        let isLoading = providerTabs.first(where: { $0.provider == selectedProvider })?.isAnalyzing == true
        let error = providerTabs.first(where: { $0.provider == selectedProvider })?.error
        return VStack(spacing: 8) {
            if isLoading {
                HStack(spacing: 8) {
                    AnimatedSparkleIcon(isAnimating: true)
                    Text("Analyzing\u{2026}", comment: "Placeholder shown while the selected AI provider is being queried")
                }
            } else if let error {
                Text(error).multilineTextAlignment(.center)
                if let selectedProvider {
                    Button("Retry") { onRetryProvider?(selectedProvider) }
                }
            } else {
                Text(
                    "No results from this provider.",
                    comment: "Placeholder when the selected AI provider tab failed and returned no results"
                )
                .font(.body)
                .foregroundColor(.secondary)
            }
        }
        .font(.body)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 24)
    }

    // MARK: - Provider Tab Bar

    private var providerTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(providerTabs) { tab in
                    providerTabButton(tab)
                }
            }
        }
        .padding(.vertical, 4)
        // Parent views (e.g. AIFoodAnalysisView) wrap food-item count changes in
        // `withAnimation`; switching tabs changes the item count so that ambient
        // animation was cascading into the tab bar and making the tabs themselves
        // look like they were sliding. Strip any inherited animation here — the tab
        // bar should switch selection crisply with no layout motion.
        .transaction { $0.animation = nil }
    }

    private func providerTabButton(_ tab: FoodProviderTab) -> some View {
        let isSelected = tab.provider == selectedProvider
        return Button(action: {
            commitAnyPendingEdit(except: nil)
            onSelectProvider?(tab.provider)
        }) {
            HStack(spacing: 6) {
                // Fixed-size slot so the spinner appearing/disappearing doesn't
                // reflow the tab's layout.
                ZStack {
                    if tab.isAnalyzing {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                .frame(width: 14, height: 14)

                // Constant weight keeps the text metrics stable across selection changes.
                Text("\(tab.provider.openRouterShortDisplayName) · \(tab.provider.openRouterProviderName)")
                    .font(.footnote.weight(.medium))
                    .foregroundColor(isSelected ? .primary : .secondary)
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color(.secondarySystemFill) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.provider)
        .help(tab.provider)
    }

    // MARK: - Nutrient Helpers

    private func cycleNutrient() {
        withAnimation(.easeInOut(duration: 0.15)) {
            nutrientDisplay = nutrientDisplay.next
        }
    }

    // MARK: - Nutrient Value View

    /// Displays a nutrient value with an inline label, tappable to cycle
    private func nutrientValueView(item: AIFoodItem, isSelected: Bool, isPending: Bool) -> some View {
        HStack(spacing: 4) {
            if isPending {
                AnimatedSparkleIcon(isAnimating: true)
            }
            AnimatedNutrientValue(
                carbs: item.carbs,
                fat: item.fat,
                protein: item.protein,
                mode: nutrientDisplay,
                valueFont: .body,
                altValueFont: .caption,
                unitFont: .caption2,
                valueColor: isSelected ? .primary : .secondary,
                unitColor: .secondary
            )
        }
        .fixedSize()
        .contentShape(Rectangle())
        .onTapGesture {
            cycleNutrient()
        }
    }

    /// Displays the total nutrient value for the header
    private func headerNutrientValueView(selection: FoodItemSelection, isPending: Bool) -> some View {
        HStack(spacing: 4) {
            if isPending {
                AnimatedSparkleIcon(isAnimating: true)
            }
            AnimatedNutrientValue(
                carbs: selection.selectedCarbs,
                fat: selection.selectedFat,
                protein: selection.selectedProtein,
                mode: nutrientDisplay,
                valueFont: .body,
                altValueFont: .caption,
                unitFont: .caption2,
                valueColor: .primary,
                unitColor: .secondary
            )
        }
        .fixedSize()
        .contentShape(Rectangle())
        .onTapGesture {
            cycleNutrient()
        }
    }

    // MARK: - Header

    private func collapsedHeader(selection: FoodItemSelection) -> some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 16)

                Text(selection.collapsedSummary)
                    .font(.body)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                // Total nutrient value with shimmer when any item is pending
                headerNutrientValueView(
                    selection: selection,
                    isPending: isAnyItemPending
                )
                .padding(.horizontal, isAnyItemPending ? 12 : 0)
                .padding(.vertical, isAnyItemPending ? 6 : 0)
                .background(
                    Group {
                        if isAnyItemPending {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(.secondarySystemFill))
                        }
                    }
                )
                .totalShimmer(isAnimating: isAnyItemPending)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Expanded Content

    private func expandedContent(selection: FoodItemSelection) -> some View {
        VStack(spacing: 0) {
            ForEach(selection.response.foodItems) { item in
                let isPending = pendingItemIds.contains(item.id)
                let isEditing = editingItemId == item.id

                foodItemRow(
                    item: item,
                    isSelected: selection.isSelected(item.id),
                    isPending: isPending,
                    isEditing: isEditing
                )

                if item.id != selection.response.foodItems.last?.id {
                    Divider()
                        .padding(.leading, 32)
                }
            }
        }
    }

    private func foodItemRow(
        item: AIFoodItem,
        isSelected: Bool,
        isPending: Bool,
        isEditing: Bool
    ) -> some View {
        HStack(spacing: 8) {
            // Checkbox
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .onTapGesture {
                    commitAnyPendingEdit(except: item.id)
                    onToggleItem(item.id)
                }

            // Emoji
            if let emoji = item.emoji, !emoji.isEmpty {
                Text(emoji)
                    .font(.body)
            }

            // Name (editable)
            if isEditing {
                // Editing mode - show text field
                TextField("", text: $editText)
                    .font(.body)
                    .foregroundColor(.primary)
                    .focused($isEditingFocused)
                    .onSubmit {
                        commitEdit(for: item)
                    }
                    .submitLabel(.done)
            } else {
                // Display mode - tappable to edit (use onTapGesture, not Button, to avoid
                // multiple .borderless buttons in the same HStack stealing each other's taps)
                Text(item.name)
                    .font(.body)
                    .foregroundColor(
                        isPending ? Color(hue: 0.75, saturation: 0.5, brightness: 0.7) :
                            (isSelected ? .primary : .secondary)
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .onTapGesture {
                        commitAnyPendingEdit(except: item.id)
                        if onEditItem != nil, !isPending {
                            startEditing(item: item)
                        }
                    }

                // Source badge for published nutrition items
                if item.source == .published {
                    PublishedBadge(
                        style: .badge,
                        items: [item],
                        onAccept: { id in onAcceptPublished?(id) },
                        onReject: { id in onRejectPublished?(id) }
                    )
                }
            }

            Spacer(minLength: 8)

            // Nutrient value - tappable to cycle between carbs/fat/protein
            nutrientValueView(
                item: item,
                isSelected: isSelected,
                isPending: isPending
            )
            .padding(.horizontal, isPending ? 10 : 0)
            .padding(.vertical, isPending ? 4 : 0)
            .background(
                Group {
                    if isPending {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(.secondarySystemFill))
                    }
                }
            )
            .shimmer(isAnimating: isPending)
        }
        .padding(.vertical, 8)
        .padding(.leading, 4)
        .padding(.horizontal, isPending ? 4 : 0)
        .background(
            Group {
                if isPending {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(.secondarySystemFill).opacity(0.5))
                }
            }
        )
        .totalShimmer(isAnimating: isPending)
    }

    private var refineWithAIButton: some View {
        Button(action: {
            // Commit any pending edit before opening chat
            if let editingId = editingItemId,
               let item = selection?.response.foodItems.first(where: { $0.id == editingId })
            {
                commitEdit(for: item)
            }
            onOpenChat?()
        }) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 14))
                Text("Refine with AI", comment: "Button to open AI chat for refining food analysis")
                    .font(.subheadline)
            }
            .foregroundColor(.accentColor)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .disabled(isAnyItemPending)
        .opacity(isAnyItemPending ? 0.5 : 1.0)
    }

    // MARK: - Editing Helpers

    /// Commits any pending edit for a different item (used when tapping other interactive elements).
    /// Pass `nil` to commit any pending edit regardless of which item it belongs to.
    private func commitAnyPendingEdit(except itemId: UUID?) {
        if let editingId = editingItemId, editingId != itemId {
            if let editingItem = selection?.response.foodItems.first(where: { $0.id == editingId }) {
                commitEdit(for: editingItem)
            }
        }
    }

    private func startEditing(item: AIFoodItem) {
        editingItemId = item.id
        editText = item.name
        isEditingFocused = true
    }

    private func commitEdit(for item: AIFoodItem) {
        let trimmedText = editText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Only call edit handler if the text actually changed
        if !trimmedText.isEmpty, trimmedText != item.name {
            onEditItem?(item.id, trimmedText)
        }

        // Clear editing state
        editingItemId = nil
        editText = ""
        isEditingFocused = false
    }
}

#if DEBUG
    struct FoodItemsSelectionView_Previews: PreviewProvider {
        static var previews: some View {
            let sampleItems = [
                AIFoodItem(name: "Sandwich (turkey, cheese)", carbs: 32, emoji: "🥪", fat: 14, protein: 22),
                AIFoodItem(name: "Apple", carbs: 15, emoji: "🍎", fat: 0, protein: 0),
                AIFoodItem(name: "Diet Soda", carbs: 0, emoji: "🥤", fat: 0, protein: 0)
            ]
            let response = AIFoodItemsResponse(foodItems: sampleItems, overallConfidence: 0.85)
            let pendingIds: Set<UUID> = [sampleItems[1].id]

            return VStack {
                StatefulPreviewWrapper(FoodItemSelection(response: response)) { selection in
                    StatefulPreviewWrapper(true) { isExpanded in
                        FoodItemsSelectionView(
                            selection: Binding(
                                get: { selection.wrappedValue },
                                set: { selection.wrappedValue = $0! }
                            ),
                            isExpanded: isExpanded,
                            pendingItemIds: pendingIds,
                            onToggleItem: { itemId in
                                selection.wrappedValue.toggleSelection(for: itemId)
                            },
                            onEditItem: { itemId, newDescription in
                                print("Edit item \(itemId): \(newDescription)")
                            },
                            onOpenChat: {
                                print("Open chat")
                            }
                        )
                        .padding()
                        .background(Color(.secondarySystemGroupedBackground))
                        .cornerRadius(10)
                        .padding()
                    }
                }
            }
        }
    }

    struct StatefulPreviewWrapper<Value, Content: View>: View {
        @State var value: Value
        var content: (Binding<Value>) -> Content

        init(_ value: Value, @ViewBuilder content: @escaping (Binding<Value>) -> Content) {
            _value = State(initialValue: value)
            self.content = content
        }

        var body: some View {
            content($value)
        }
    }
#endif
