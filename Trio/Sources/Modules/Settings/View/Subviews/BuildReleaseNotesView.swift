import SwiftUI

extension Settings {
    struct BuildReleaseNotesLink: View {
        let commitSHA: String

        @State private var notes: BuildReleaseNotes?

        var body: some View {
            Group {
                if let notes {
                    NavigationLink(destination: BuildReleaseNotesView(notes: notes)) {
                        Label("Build Release Notes", systemImage: "doc.text.magnifyingglass")
                    }
                }
            }
            .task(id: commitSHA) {
                notes = await BuildReleaseNotesClient.shared.fetch(commitSHA: commitSHA)
            }
        }
    }

    private struct BuildReleaseNotesView: View {
        let notes: BuildReleaseNotes

        @Environment(\.colorScheme) private var colorScheme
        @Environment(AppState.self) private var appState

        var body: some View {
            List {
                if notes.highlights.isNotEmpty {
                    Section("Highlights") {
                        noteItems(notes.highlights)
                    }
                    .listRowBackground(Color.chart)
                }

                ForEach(
                    Array(notes.categories.filter { $0.category != "highlights" }.enumerated()),
                    id: \.offset
                ) { _, category in
                    let items = category.items.filter { !$0.highlight }
                    if items.isNotEmpty {
                        Section(category.title) {
                            noteItems(items)
                        }
                        .listRowBackground(Color.chart)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle("Build Release Notes")
            .navigationBarTitleDisplayMode(.inline)
        }

        @ViewBuilder private func noteItems(_ items: [BuildReleaseNotes.Item]) -> some View {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                    ForEach(item.changes, id: \.self) { change in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•")
                            Text(change)
                        }
                        .font(.footnote)
                    }
                    if item.humanReviewRequired {
                        Label("Human review recommended", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    if let source = item.sources.first {
                        SwiftUI.Link(destination: source.url) {
                            Label("View source on GitHub", systemImage: "arrow.up.right.square")
                                .font(.footnote)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}
