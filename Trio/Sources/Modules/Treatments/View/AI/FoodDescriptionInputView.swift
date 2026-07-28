import SwiftUI

/// Inline view for reviewing initial AI analysis and adding optional context.
/// Shown below the AI button after a photo is captured/selected.
struct FoodDescriptionInputView: View {
    @Binding var description: String
    let imageData: Data
    let isPreparingAnalysis: Bool
    let provisionalItems: [AIFoodItem]
    let provisionalError: String?
    let onContinue: () -> Void
    let onCancel: () -> Void

    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            // Photo thumbnail + description input
            HStack(alignment: .top, spacing: 12) {
                // Thumbnail
                if let uiImage = UIImage(data: imageData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 64, height: 64)
                        .cornerRadius(8)
                        .clipped()
                }

                // Description field
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add context (optional)", comment: "Label for food description text field")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ZStack(alignment: .topLeading) {
                        if description.isEmpty {
                            Text("e.g., sugar-free, homemade…", comment: "Placeholder for food description")
                                .font(.subheadline)
                                .foregroundColor(Color(.placeholderText))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 8)
                        }
                        TextEditor(text: $description)
                            .font(.subheadline)
                            .frame(minHeight: 44, maxHeight: 64)
                            .padding(.horizontal, 2)
                            .padding(.vertical, 2)
                            .focused($isTextFieldFocused)
                    }
                    .background(Color(.systemGray6))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(.systemGray4), lineWidth: 0.5)
                    )
                }
            }

            initialAnalysisCard

            // Example chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    exampleChip("No sugar added")
                    exampleChip("Homemade")
                    exampleChip("Large portion")
                    exampleChip("Low carb")
                    exampleChip("McDonald's")
                    exampleChip("Starbucks")
                    exampleChip("Chipotle")
                }
            }

            // Action buttons
            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Text("Cancel", comment: "Cancel description input")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)

                Spacer()

                Button(action: onContinue) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.subheadline)
                        Text("Continue", comment: "Button to continue with the initial food analysis")
                            .font(.subheadline.bold())
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Color.accentColor)
                    .cornerRadius(8)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 8)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isTextFieldFocused = true
            }
        }
    }

    @ViewBuilder private var initialAnalysisCard: some View {
        if isPreparingAnalysis || !provisionalItems.isEmpty || provisionalError != nil {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    if isPreparingAnalysis {
                        ProgressView()
                            .controlSize(.small)
                        if provisionalItems.isEmpty {
                            Text(
                                "Analyzing image…",
                                comment: "Status shown while immediate food image analysis waits for its first result"
                            )
                        } else {
                            Text(
                                "Initial analysis updating…",
                                comment: "Status shown while immediate food image analysis streams provisional results"
                            )
                        }
                    } else if let provisionalError {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                        Text(provisionalError)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(
                            "Initial analysis ready",
                            comment: "Status shown when immediate food image analysis has completed"
                        )
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(provisionalItems) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "\(item.emoji ?? "") \(item.name)")
                            .font(.caption)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(
                            verbatim:
                            "C \(item.carbs.formatted(.number.precision(.fractionLength(0 ... 1))))g · F \(item.fat.formatted(.number.precision(.fractionLength(0 ... 1))))g · P \(item.protein.formatted(.number.precision(.fractionLength(0 ... 1))))g"
                        )
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }

                if !provisionalItems.isEmpty {
                    Divider()
                    HStack {
                        Text("Preliminary total", comment: "Label for provisional total carbohydrate estimate")
                            .font(.caption.bold())
                        Spacer()
                        Text(
                            verbatim:
                            "\(provisionalItems.reduce(0) { $0 + $1.carbs }.formatted(.number.precision(.fractionLength(0 ... 1)))) g carbs"
                        )
                        .font(.caption.bold().monospacedDigit())
                    }
                }
            }
            .padding(10)
            .background(Color(.secondarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func exampleChip(_ text: String) -> some View {
        Button(action: {
            if description.isEmpty {
                description = text.lowercased()
            } else {
                description += ", \(text.lowercased())"
            }
        }) {
            Text(text)
                .font(.caption2)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(.secondarySystemFill))
                .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
    struct FoodDescriptionInputView_Previews: PreviewProvider {
        static var previews: some View {
            FoodDescriptionInputView(
                description: .constant(""),
                imageData: Data(),
                isPreparingAnalysis: true,
                provisionalItems: [],
                provisionalError: nil,
                onContinue: {},
                onCancel: {}
            )
            .padding()
        }
    }
#endif
