import SwiftUI
import Swinject

extension Main {
    struct RootView: BaseView {
        let resolver: Resolver
        @StateObject var state = StateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        var body: some View {
            router.view(for: .home)
                .sheet(item: $state.modal) { modal in
                    NavigationView {
                        modal.view
                            // DEBUG #882: Log safe area inside the presented sheet
                            .background(
                                GeometryReader { sheetGeo in
                                    Color.clear
                                        .onAppear {
                                            debugLog882(
                                                "🟣",
                                                "Sheet OPENED (\(modal.screen)) — safe area top: \(sheetGeo.safeAreaInsets.top), bottom: \(sheetGeo.safeAreaInsets.bottom)"
                                            )
                                        }
                                        .onChange(of: sheetGeo.safeAreaInsets.bottom) { oldVal, newVal in
                                            debugLog882("🟣", "Sheet bottom inset CHANGED: \(oldVal) → \(newVal)")
                                        }
                                        .onDisappear {
                                            debugLog882("🟣", "Sheet CLOSED (\(modal.screen))")
                                        }
                                }
                            )
                    }
                    .navigationViewStyle(StackNavigationViewStyle())
                }
                .sheet(item: $state.secondaryModal) { wrapper in
                    wrapper.view
                }
                .onChange(of: state.modal) { oldVal, newVal in
                    if newVal == nil, oldVal != nil {
                        // Sheet just dismissed — log the parent safe area
                        debugLog882("🔵", "Modal dismissed, checking parent safe area...")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                               let window = windowScene.windows.first
                            {
                                debugLog882("🔵", "Window safe area after dismiss — bottom: \(window.safeAreaInsets.bottom)")
                            }
                        }
                    }
                }
                .onAppear(perform: configureView)
                .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
        }
    }
}
