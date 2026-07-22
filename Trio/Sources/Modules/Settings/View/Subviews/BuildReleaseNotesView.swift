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

    static func buildTitle(_ notes: BuildReleaseNotes) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: notes.metadata.buildDate) else {
            return "Build \(notes.metadata.shortSha)"
        }
        return "Build \(notes.metadata.shortSha) · \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    static func buildDate(_ notes: BuildReleaseNotes) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: notes.metadata.buildDate)
    }

    /// A group of builds that share the same calendar month, newest month first.
    struct MonthGroup: Identifiable {
        let id: String
        let title: String
        let builds: [BuildReleaseNotes]
    }

    /// Groups builds (already newest-first) into calendar-month sections, preserving order.
    static func monthGroups(_ builds: [BuildReleaseNotes]) -> [MonthGroup] {
        let keyFormatter = DateFormatter()
        keyFormatter.locale = Locale(identifier: "en_US_POSIX")
        keyFormatter.dateFormat = "yyyy-MM"

        let titleFormatter = DateFormatter()
        titleFormatter.locale = Locale.current
        titleFormatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")

        var order: [String] = []
        var byKey: [String: (title: String, builds: [BuildReleaseNotes])] = [:]

        for notes in builds {
            let date = buildDate(notes)
            let key = date.map { keyFormatter.string(from: $0) } ?? "unknown"
            let title = date.map { titleFormatter.string(from: $0) } ?? String(localized: "Earlier Builds")
            if byKey[key] == nil {
                byKey[key] = (title, [])
                order.append(key)
            }
            byKey[key]?.builds.append(notes)
        }

        return order.map { key in
            MonthGroup(id: key, title: byKey[key]!.title, builds: byKey[key]!.builds)
        }
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
    @State private var unseenSHAsAtLoad: Set<String>? = nil

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
                ForEach(BuildReleaseNotesState.monthGroups(builds)) { group in
                    Section(group.title) {
                        ForEach(Array(group.builds.enumerated()), id: \.offset) { _, notes in
                            NavigationLink {
                                BuildDetailView(notes: notes)
                            } label: {
                                buildRow(notes, isUnseen: unseenSHAs.contains(notes.metadata.shortSha.lowercased()))
                            }
                            .listRowBackground(Color.chart)
                        }
                    }
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
            unseenSHAsAtLoad = Set(
                BuildReleaseNotesState.unseenBuilds(in: builds, after: lastSeenSHA)
                    .map { $0.metadata.shortSha.lowercased() }
            )
            if markSeenOnLoad, let newest = builds.first {
                lastSeenSHA = newest.metadata.shortSha.lowercased()
            }
        }
    }

    private var unseenSHAs: Set<String> {
        unseenSHAsAtLoad ?? Set(
            BuildReleaseNotesState.unseenBuilds(in: builds, after: lastSeenSHA)
                .map { $0.metadata.shortSha.lowercased() }
        )
    }

    @ViewBuilder private func buildRow(_ notes: BuildReleaseNotes, isUnseen: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(rowDate(notes))
                    .font(.subheadline.weight(.semibold))
                Text(notes.metadata.shortSha)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if isInstalledBuild(notes) {
                    tag("This Build", color: Color.accentColor)
                }
                if isUnseen {
                    tag("New", color: .red)
                }
            }
            let titles = summaryTitles(notes)
            if titles.isEmpty {
                Text("No user-facing changes")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                let shown = titles.prefix(summaryLimit)
                ForEach(Array(shown.enumerated()), id: \.offset) { _, title in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                        Text(title)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                if titles.count > summaryLimit {
                    Text("+\(titles.count - summaryLimit) more")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private let summaryLimit = 3

    private func rowDate(_ notes: BuildReleaseNotes) -> String {
        guard let date = BuildReleaseNotesState.buildDate(notes) else {
            return "Build"
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func tag(_ text: LocalizedStringKey, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
    }

    /// High-level summary for the list: the title of each highlight/change, without bullet detail.
    private func summaryTitles(_ notes: BuildReleaseNotes) -> [String] {
        let highlightTitles = notes.highlights.map(\.title)
        let categoryTitles = notes.categories
            .filter { $0.category != "highlights" }
            .flatMap { $0.items.filter { !$0.highlight }.map(\.title) }
        return highlightTitles + categoryTitles
    }

    private func isInstalledBuild(_ notes: BuildReleaseNotes) -> Bool {
        notes.metadata.shortSha.lowercased() == BuildReleaseNotesState.shortSHA(BuildDetails.shared.trioCommitSHA)
    }
}

private struct BuildDetailView: View {
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
        .navigationTitle(BuildReleaseNotesState.buildTitle(notes))
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
