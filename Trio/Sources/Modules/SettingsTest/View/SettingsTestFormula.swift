import SwiftUI

// Shared pieces for the guided settings tests that explain themselves: an info sheet that quotes the Trio docs,
// and a formula card laid out like the Bolus Calculator Details sheet (see `PopupView`).

// MARK: - Info

/// What a tappable row explains: the Trio docs passage it rests on, what the row reads now, the point in plain words,
/// and named links to the docs pages.
struct SettingsTestInfo: Identifiable {
    let id = UUID()
    let title: String
    let body: String
    /// What the row reads now, in a sentence, when its one-line value leaves something out.
    let reading: String?
    let quote: String?
    let links: [SettingsTestDocsLink]

    init(
        title: String,
        body: String,
        reading: String? = nil,
        quote: String? = nil,
        links: [SettingsTestDocsLink] = []
    ) {
        self.title = title
        self.body = body
        self.reading = reading
        self.quote = quote
        self.links = links
    }
}

struct SettingsTestInfoSheet: View {
    let info: SettingsTestInfo

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationStack {
            // The sheet paints its own background, so the screen doesn't.
            SettingsTestScreen(paintsBackground: false) {
                SettingsTestCard {
                    if let quote = info.quote {
                        SettingsTestDocsQuote(text: quote)
                    }

                    if let reading = info.reading {
                        Text(reading)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(info.body)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !info.links.isEmpty {
                        SettingsTestDocsLinks(links: info.links)
                    }
                }
            }
            .navigationTitle(info.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        // Opaque, so the screen underneath doesn't show through the medium detent's glass. In light mode the grouped
        // background, so the white card stands out (as `GRIView` does); in dark mode Trio's own gradient.
        .presentationBackground {
            if colorScheme == .dark {
                appState.trioBackgroundColor(for: colorScheme)
            } else {
                Color(uiColor: .systemGroupedBackground)
            }
        }
    }
}

// MARK: - Formula

/// One value in a formula: a label above it, the value itself and its unit below.
struct SettingsTestFormulaTerm {
    let label: String
    let value: String
    let unit: String
    /// Shown in the accent colour, so the user can tell their own settings from what the test measured.
    /// Applies to formula terms only: a result is always neutral bold.
    let fromSettings: Bool
    /// How VoiceOver says the unit, when spelling out its letters isn't enough (e.g. "h").
    let spokenUnit: String?

    init(label: String, value: String, unit: String, fromSettings: Bool, spokenUnit: String? = nil) {
        self.label = label
        self.value = value
        self.unit = unit
        self.fromSettings = fromSettings
        self.spokenUnit = spokenUnit
    }
}

enum SettingsTestFormulaPart {
    case term(SettingsTestFormulaTerm)
    case op(String)
}

/// Formulas laid out like the Bolus Calculator Details sheet: labels above, values in the middle, units below.
/// `result[i]` is the answer to `rows[i]`, shown after the "=". Only the rows that have a result are shown.
/// `conclusion` is a line under the formulas that says what the answer means.
struct SettingsTestFormulaCard: View {
    let title: String
    let rows: [[SettingsTestFormulaPart]]
    let result: [SettingsTestFormulaTerm]
    var conclusion: Text?

    private var lineCount: Int {
        min(rows.count, result.count)
    }

    private var usesSettings: Bool {
        rows.prefix(lineCount).contains { parts in
            parts.contains { part in
                if case let .term(term) = part {
                    return term.fromSettings
                }
                return false
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsTestCard(title: title) {
                VStack(spacing: 16) {
                    ForEach(0 ..< lineCount, id: \.self) { index in
                        line(rows[index], result: result[index])
                            // One spoken sentence per line, in reading order, instead of its cells column by column.
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text(Self.spokenLabel(rows[index], result: result[index])))
                    }
                }

                if let conclusion {
                    Divider()
                    conclusion
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .contain)

            if usesSettings {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "gearshape")
                        .accessibilityHidden(true)
                    Text("Blue values come from your settings")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            }
        }
    }

    /// A formula line as VoiceOver reads it: each term's label, value and unit, the operators as words, and which
    /// values come from the user's settings, since the screen shows that by colour alone.
    static func spokenLabel(_ parts: [SettingsTestFormulaPart], result: SettingsTestFormulaTerm) -> String {
        func spoken(_ term: SettingsTestFormulaTerm) -> String {
            let unit = term.spokenUnit ?? UnitSpelling.spoken(term.unit)
            let said = [term.label, term.value, unit].filter { !$0.isEmpty }.joined(separator: " ")
            return term.fromSettings ? said + ", " + String(localized: "from your settings") : said
        }
        func word(for symbol: String) -> String {
            switch symbol {
            case "÷": return String(localized: "divided by")
            case "×": return String(localized: "times")
            case "+": return String(localized: "plus")
            case "-",
                 "−": return String(localized: "minus")
            default: return symbol
            }
        }
        let formula = parts.map { part -> String in
            switch part {
            case let .term(term): return spoken(term)
            case let .op(symbol): return word(for: symbol)
            }
        }
        return (formula + [String(localized: "equals"), spoken(result)]).joined(separator: ", ")
    }

    /// Every part adds one cell to each of the three rows, so the columns line up. A flexible spacer column before
    /// the "=" pushes the formula to the left and the answer to the right, and gives way first when space runs out,
    /// so the "=" itself is never squeezed out.
    private func line(_ parts: [SettingsTestFormulaPart], result: SettingsTestFormulaTerm) -> some View {
        Grid(alignment: .center, horizontalSpacing: 4) {
            GridRow(alignment: .lastTextBaseline) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    switch part {
                    case let .term(term):
                        Text(term.label)
                            .formulaLabelStyle(highlighted: term.fromSettings)
                    case .op:
                        blankCell
                    }
                }
                spacerCell
                blankCell
                Text(result.label)
                    .formulaLabelStyle(highlighted: false)
            }

            GridRow {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    switch part {
                    case let .term(term):
                        Text(term.value)
                            .formulaValueStyle(highlighted: term.fromSettings)
                    case let .op(symbol):
                        Text(verbatim: symbol)
                            .formulaOperatorStyle()
                    }
                }
                spacerCell
                Text(verbatim: "=")
                    .formulaOperatorStyle()
                    .fixedSize()
                Text(result.value)
                    .formulaResultStyle()
            }

            GridRow(alignment: .firstTextBaseline) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    switch part {
                    case let .term(term):
                        Text(term.unit)
                    case .op:
                        blankCell
                    }
                }
                spacerCell
                blankCell
                Text(result.unit)
            }
            .formulaUnitStyle()
        }
        .multilineTextAlignment(.center)
    }

    private var blankCell: some View {
        Text("")
            .layoutPriority(-15)
    }

    private var spacerCell: some View {
        Color.clear
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: 1)
            .layoutPriority(-20)
    }
}

// The styles of the Bolus Calculator Details formulas, which are private to `PopupView.swift`. Labels and units stay
// on one line and shrink rather than break mid-word at large text sizes.
private extension View {
    /// A label above a value; the accent colour marks a value that comes from the user's settings.
    func formulaLabelStyle(highlighted: Bool) -> some View {
        font(.footnote)
            .foregroundStyle(highlighted ? Color.accentColor : Color.secondary)
            .allowsTightening(true)
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .layoutPriority(1)
    }

    func formulaValueStyle(highlighted: Bool) -> some View {
        font(.headline)
            .foregroundStyle(highlighted ? Color.accentColor : Color.primary)
            .frame(minWidth: 44)
            .allowsTightening(true)
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .layoutPriority(5)
    }

    /// Never below 0.8, so "÷" doesn't shrink until it looks like ":".
    func formulaOperatorStyle() -> some View {
        font(.body)
            .foregroundStyle(.secondary)
            .allowsTightening(true)
            .minimumScaleFactor(0.8)
            .lineLimit(1)
            .layoutPriority(3)
    }

    /// Applied to a whole `GridRow` of units.
    func formulaUnitStyle() -> some View {
        font(.caption2)
            .foregroundStyle(.secondary)
            .allowsTightening(true)
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .layoutPriority(-1)
    }

    /// Neutral bold: the header's icon carries the direction, and colour is kept for the values from settings.
    func formulaResultStyle() -> some View {
        font(.system(.headline, weight: .bold))
            .frame(minWidth: 45, alignment: .center)
            .foregroundStyle(Color.primary)
            .allowsTightening(true)
            .fixedSize(horizontal: true, vertical: true)
            .minimumScaleFactor(0.5)
            .layoutPriority(10)
            .lineLimit(1)
    }
}
