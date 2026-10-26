import SwiftUI
import Swinject

extension SettingsTest {
    /// The hub: every guided test in one place, with when each was last run.
    struct RootView: BaseView {
        let resolver: Resolver

        @State var state = StateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        var body: some View {
            List {
                if let session = state.activeSession {
                    Section {
                        activeBanner(for: session)
                    }
                    .listRowBackground(Color.chart)
                }

                Section(
                    header: Text("Check Your Settings"),
                    footer: Text(
                        "Each test shows you which way a setting leans. You decide whether to change it. Work in this order: basal first, then insulin sensitivity, then carb ratio."
                    )
                ) {
                    ForEach(SettingsTestKind.allCases) { kind in
                        row(for: kind)
                    }
                }
                .listRowBackground(Color.chart)
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle("Settings Tests")
            .navigationBarTitleDisplayMode(.automatic)
            .onAppear(perform: configureView)
        }

        // MARK: - Rows

        @ViewBuilder private func row(for kind: SettingsTestKind) -> some View {
            if let screen = state.screen(for: kind), kind.isAvailable {
                rowContent(for: kind).navigationLink(to: screen, from: self)
            } else {
                rowContent(for: kind).opacity(0.55)
            }
        }

        private func rowContent(for kind: SettingsTestKind) -> some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: kind.icon)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.title)
                        .font(.body.weight(.medium))
                    Text(kind.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(lastTestedText(for: kind))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
            .padding(.vertical, 4)
        }

        private func lastTestedText(for kind: SettingsTestKind) -> String {
            guard kind.isAvailable else { return String(localized: "Coming soon") }
            guard let record = state.lastRecords[kind] else { return String(localized: "Not tested yet") }
            let when = record.completedAt.formatted(.relative(presentation: .named))
            return String(localized: "Last tested \(when)")
        }

        private func activeBanner(for session: SettingsTestSession) -> some View {
            HStack(spacing: 12) {
                Image(systemName: "timer")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(session.kind.title) test in progress")
                        .font(.subheadline.weight(.semibold))
                    Text("Open it below to follow along or stop it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
