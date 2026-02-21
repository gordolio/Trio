import SwiftUI

/// Full-screen chat modal for refining food analysis with AI
struct AIChatView: View {
    @ObservedObject var conversationManager: AIConversationManager
    @Binding var isPresented: Bool
    let onAcceptValues: (FoodItemSelection) -> Void

    let onAcceptPublished: ((UUID) -> Void)?
    let onRejectPublished: ((UUID) -> Void)?

    @State private var inputText = ""
    @State private var verifyingItem: AIFoodItem?
    @FocusState private var isInputFocused: Bool

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Sticky header with current totals
                stickyHeader

                Divider()

                // Chat message list
                ChatMessageList(
                    messages: conversationManager.messages,
                    isProcessing: conversationManager.isProcessing,
                    onAccept: acceptAndClose,
                    onVerifyPublishedItem: { item in
                        verifyingItem = item
                    }
                )

                Divider()

                // Input area
                chatInputArea
            }
            .navigationTitle(Text("Refine Food Analysis", comment: "Title for AI chat view"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { isPresented = false }) {
                        Text("Cancel", comment: "Cancel button")
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: acceptAndClose) {
                        Text("Confirm", comment: "Confirm button")
                            .bold()
                    }
                    .disabled(conversationManager.isProcessing)
                }
            }
            .sheet(item: $verifyingItem) { item in
                if let urlString = item.sourceURL, let url = URL(string: urlString) {
                    PublishedSourceVerificationView(
                        url: url,
                        item: item,
                        onAccept: { onAcceptPublished?(item.id) },
                        onReject: { onRejectPublished?(item.id) }
                    )
                }
            }
            .alert(
                Text("Error", comment: "Error alert title"),
                isPresented: Binding(
                    get: { conversationManager.errorMessage != nil },
                    set: { if !$0 { conversationManager.clearError() } }
                ),
                actions: {
                    Button("OK") {
                        conversationManager.clearError()
                    }
                },
                message: {
                    Text(conversationManager.errorMessage ?? "")
                }
            )
        }
    }

    // MARK: - Sticky Header

    private var stickyHeader: some View {
        CompactCarbSummaryView(
            items: conversationManager.currentItems,
            isUpdating: conversationManager.isProcessing,
            onExpand: { /* Could show expanded view */ },
            onAccept: acceptAndClose
        )
    }

    // MARK: - Chat Input

    private var chatInputArea: some View {
        HStack(alignment: .bottom, spacing: 12) {
            // Text input - auto-growing TextField like iMessage
            TextField(
                String(localized: "Type a message...", comment: "Placeholder for chat input"),
                text: $inputText,
                axis: .vertical
            )
            .lineLimit(1 ... 5)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .focused($isInputFocused)
            .background(Color(.systemGray6))
            .cornerRadius(18)
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color(.systemGray4), lineWidth: 0.5)
            )

            // Send button
            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(canSend ? .accentColor : .secondary)
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !conversationManager.isProcessing
    }

    // MARK: - Actions

    private func sendMessage() {
        let trimmedText = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        inputText = ""
        isInputFocused = false

        Task {
            await conversationManager.sendMessage(trimmedText)
        }
    }

    private func acceptAndClose() {
        let selection = conversationManager.acceptCurrentValues()
        onAcceptValues(selection)
        isPresented = false
    }
}

#if DEBUG
    struct AIChatView_Previews: PreviewProvider {
        static var previews: some View {
            let sampleItems = [
                AIFoodItem(name: "Sandwich", carbs: 32, emoji: "🥪", fat: 12, protein: 18),
                AIFoodItem(name: "Apple", carbs: 15, emoji: "🍎", fat: 0, protein: 0)
            ]
            let response = AIFoodItemsResponseWithReasoning(
                foodItems: sampleItems,
                overallConfidence: 0.85,
                reasoning: "I see a turkey sandwich on white bread and a medium-sized red apple. The sandwich appears to have about 2 slices of bread."
            )

            let manager = AIConversationManager()

            return AIChatView(
                conversationManager: manager,
                isPresented: .constant(true),
                onAcceptValues: { _ in print("Accepted") },
                onAcceptPublished: nil,
                onRejectPublished: nil
            )
            .onAppear {
                // Initialize manager with sample data for preview
                Task { @MainActor in
                    manager.initialize(
                        with: response,
                        imageData: Data(),
                        userDescription: nil
                    )
                }
            }
        }
    }
#endif
