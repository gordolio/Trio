import Foundation
import SwiftUI

private enum BuildReleaseNotesState {
    static let lastSeenSHAKey = "buildReleaseNotes.lastSeenSHA"

    static func shortSHA(_ sha: String) -> String {
        String(sha.lowercased().prefix(7))
    }

    static func initialLastSeenSHA(
        builds: [BuildReleaseNotes],
        installedSHA: String
    ) -> String {
        guard let latest = builds.first else {
            return shortSHA(installedSHA)
        }

        let installedShortSHA = shortSHA(installedSHA)
        if latest.metadata.shortSha.lowercased() == installedShortSHA,
           let previousBuiltSHA = latest.metadata.previousBuiltSha
        {
            return shortSHA(previousBuiltSHA)
        }
        return latest.metadata.shortSha.lowercased()
    }

    static func unseenBuilds(
        in builds: [BuildReleaseNotes],
        after lastSeenSHA: String
    ) -> [BuildReleaseNotes] {
        let seenSHA = shortSHA(lastSeenSHA)
        guard let seenIndex = builds.firstIndex(where: { $0.metadata.shortSha.lowercased() == seenSHA }) else {
            return builds
        }
        return Array(builds[..<seenIndex])
    }
}

extension Settings {
    struct BuildReleaseNotesLink: View {
        @AppStorage(BuildReleaseNotesState.lastSeenSHAKey) private var lastSeenSHA = ""
        @State private var builds: [BuildReleaseNotes] = []

        private var unseenCount: Int {
            BuildReleaseNotesState.unseenBuilds(in: builds, after: lastSeenSHA).count
        }

        var body: some View {
            NavigationLink {
                BuildReleaseNotesView(initialBuilds: builds, markSeenOnLoad: true)
            } label: {
                HStack {
                    Label("What's New", systemImage: "sparkles")
                    Spacer()
                    if unseenCount > 0 {
                        Text(unseenCount.formatted())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.red, in: Capsule())
                    }
                }
            }
            .task {
                builds = await BuildReleaseNotesClient.shared.fetchRecentBuilds()
                initializeLastSeenSHAIfNeeded()
            }
        }

        private func initializeLastSeenSHAIfNeeded() {
            guard lastSeenSHA.isEmpty else { return }
            lastSeenSHA = BuildReleaseNotesState.initialLastSeenSHA(
                builds: builds,
                installedSHA: BuildDetails.shared.trioCommitSHA
            )
        }
    }
}

private struct BuildReleaseNotesView: View {
    @AppStorage(BuildReleaseNotesState.lastSeenSHAKey) private var lastSeenSHA = ""
    @State private var builds: [BuildReleaseNotes]
    @State private var unseenCountAtLoad: Int? = nil

    let markSeenOnLoad: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    init(initialBuilds: [BuildReleaseNotes] = [], markSeenOnLoad: Bool = false) {
        _builds = State(initialValue: initialBuilds)
        self.markSeenOnLoad = markSeenOnLoad
    }

    var body: some View {
        List {
            if builds.isEmpty {
                ContentUnavailableView(
                    "No Release Notes Available",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Release notes will appear here after they are generated.")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(Array(builds.enumerated()), id: \.offset) { index, notes in
                    Section {
                        noteContent(notes)
                    } header: {
                        HStack {
                            Text(buildTitle(notes))
                            if index < unseenCount {
                                Text("New")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    .listRowBackground(Color.chart)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("What's New")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if builds.isEmpty {
                builds = await BuildReleaseNotesClient.shared.fetchRecentBuilds()
            }
            if lastSeenSHA.isEmpty {
                lastSeenSHA = BuildReleaseNotesState.initialLastSeenSHA(
                    builds: builds,
                    installedSHA: BuildDetails.shared.trioCommitSHA
                )
            }
            unseenCountAtLoad = BuildReleaseNotesState.unseenBuilds(in: builds, after: lastSeenSHA).count
            if markSeenOnLoad, let newest = builds.first {
                lastSeenSHA = newest.metadata.shortSha.lowercased()
            }
        }
    }

    private var unseenCount: Int {
        unseenCountAtLoad ?? BuildReleaseNotesState.unseenBuilds(in: builds, after: lastSeenSHA).count
    }

    @ViewBuilder private func noteContent(_ notes: BuildReleaseNotes) -> some View {
        if notes.highlights.isNotEmpty {
            categoryTitle("Highlights")
            noteItems(notes.highlights)
        }

        ForEach(
            Array(notes.categories.filter { $0.category != "highlights" }.enumerated()),
            id: \.offset
        ) { _, category in
            let items = category.items.filter { !$0.highlight }
            if items.isNotEmpty {
                categoryTitle(category.title)
                noteItems(items)
            }
        }
    }

    private func categoryTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
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

    private func buildTitle(_ notes: BuildReleaseNotes) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: notes.metadata.buildDate) else {
            return "Build \(notes.metadata.shortSha)"
        }
        return "Build \(notes.metadata.shortSha) · \(date.formatted(date: .abbreviated, time: .omitted))"
    }
}
