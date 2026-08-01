import SwiftUI
import WebKit

/// A sheet that displays the published nutrition source in a web view,
/// allowing the user to accept or reject the published values.
struct PublishedSourceVerificationView: View {
    let url: URL
    let item: AIFoodItem
    let onAccept: () -> Void
    let onReject: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true
    @State private var loadingProgress: Double = 0

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Loading progress bar
                if isLoading {
                    ProgressView(value: loadingProgress)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                }

                // Web view
                WebViewRepresentable(
                    url: url,
                    isLoading: $isLoading,
                    loadingProgress: $loadingProgress
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(.separator), lineWidth: 1)
                )
                .padding(.horizontal, 8)
                .padding(.bottom, 4)

                // Bottom bar: item info, nutrition summary + action buttons
                VStack(spacing: 0) {
                    Divider()

                    // Item name and source domain
                    VStack(spacing: 2) {
                        Text(item.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)
                        if let host = url.host {
                            Text(host)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                    // Nutrition summary
                    nutritionSummary
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)

                    // Action buttons
                    HStack(spacing: 16) {
                        Button(action: {
                            onReject()
                            dismiss()
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "xmark.circle.fill")
                                Text("Reject", comment: "Button to reject published nutrition value and use AI estimate instead")
                            }
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.loopRed)

                        Button(action: {
                            onAccept()
                            dismiss()
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                Text("Accept", comment: "Button to accept the published nutrition value")
                            }
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
                .background(Color(.systemGroupedBackground))
            }
            .navigationTitle(
                Text("Published Nutrition Facts", comment: "Title for the published nutrition source verification sheet")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    // MARK: - Nutrition Summary

    private var nutritionSummary: some View {
        HStack(spacing: 0) {
            nutrientColumn(
                value: item.carbs,
                label: String(localized: "Carbs", comment: "Carbohydrates nutrient label in published nutrition summary")
            )
            nutrientDivider
            nutrientColumn(
                value: item.fat,
                label: String(localized: "Fat", comment: "Fat nutrient label in published nutrition summary")
            )
            nutrientDivider
            nutrientColumn(
                value: item.protein,
                label: String(localized: "Protein", comment: "Protein nutrient label in published nutrition summary")
            )
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func nutrientColumn(value: Double, label: String, unit: String = "g") -> some View {
        VStack(spacing: 2) {
            Text(formatNutrient(value, unit: unit))
                .font(.system(.body, design: .rounded).weight(.semibold).monospacedDigit())
                .foregroundColor(.primary)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var nutrientDivider: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(width: 1, height: 28)
    }

    private func formatNutrient(_ value: Double, unit: String) -> String {
        if value == floor(value) {
            return "\(Int(value))\(unit)"
        } else {
            return String(format: "%.1f%@", value, unit)
        }
    }
}

// MARK: - WKWebView Wrapper

private struct WebViewRepresentable: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    @Binding var loadingProgress: Double

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        context.coordinator.progressObservation = webView.observe(
            \.estimatedProgress,
            options: [.new]
        ) { webView, _ in
            DispatchQueue.main.async {
                self.loadingProgress = webView.estimatedProgress
            }
        }
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_: WKWebView, context _: Context) {}

    class Coordinator: NSObject, WKNavigationDelegate {
        let parent: WebViewRepresentable
        var progressObservation: NSKeyValueObservation?

        init(parent: WebViewRepresentable) {
            self.parent = parent
        }

        func webView(_: WKWebView, didFinish _: WKNavigation!) {
            parent.isLoading = false
        }

        func webView(_: WKWebView, didFail _: WKNavigation!, withError _: Error) {
            parent.isLoading = false
        }
    }
}
