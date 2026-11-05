import SwiftUI

// A test's start as a short wizard: one question per page inside its Check step, each page with Next (or Begin) and
// Back. The basal, ISF and carb ratio tests use it.

// MARK: - Order

/// Which page of a test's start comes after or before another, among the pages that apply now (a page can be left out,
/// e.g. a question that only applies to some starts). Pure, so a state model keeps which page shows and its tests can
/// check the order.
enum SettingsTestPageFlow {
    /// The page after `current` among `pages`, nil on the last.
    static func page<Page: Equatable>(after current: Page, in pages: [Page]) -> Page? {
        guard let index = pages.firstIndex(of: current), index + 1 < pages.count else { return nil }
        return pages[index + 1]
    }

    /// The page before `current` among `pages`, nil on the first.
    static func page<Page: Equatable>(before current: Page, in pages: [Page]) -> Page? {
        guard let index = pages.firstIndex(of: current), index > 0 else { return nil }
        return pages[index - 1]
    }

    /// The page to show for `current`: itself while it applies, otherwise the nearest one before it in `order` (every page
    /// in order) that does, or the first page. So a page that stops applying while it shows hands over to the one before.
    static func shown<Page: Equatable>(_ current: Page, in pages: [Page], order: [Page]) -> Page {
        if pages.contains(current) { return current }
        guard let index = order.firstIndex(of: current) else { return pages.first ?? current }
        return order[..<index].last(where: { pages.contains($0) }) ?? pages.first ?? current
    }

    /// The page to show for `current`, given the pages shown so far (`seen`): the first page before it that applies and
    /// hasn't been shown, so a question that starts to apply behind the user (insulin on board going over the line while
    /// Ready shows) is asked before the start can be; otherwise as `shown(_:in:order:)`.
    static func shown<Page: Hashable>(_ current: Page, in pages: [Page], order: [Page], seen: Set<Page>) -> Page {
        let page = shown(current, in: pages, order: order)
        guard let index = pages.firstIndex(of: page) else { return page }
        return pages[..<index].first(where: { !seen.contains($0) }) ?? page
    }

    /// Where `page` sits among `pages`, "2 of 5". Empty when it isn't among them.
    static func position<Page: Equatable>(of page: Page, in pages: [Page]) -> String {
        guard let index = pages.firstIndex(of: page) else { return "" }
        return String(localized: "\(index + 1) of \(pages.count)")
    }
}

// MARK: - Heading

/// A page's heading after the first: its question as a title, and where it sits among the pages. VoiceOver reads them
/// as one heading, the question first, and moves to it when the page comes up, as each page is a view of its own.
struct SettingsTestPageHeading: View {
    let title: String
    /// "2 of 5" (`SettingsTestPageFlow.position`).
    let position: String

    @AccessibilityFocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !position.isEmpty {
                Text(position)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.spokenLabel(title: title, position: position)))
        .accessibilityAddTraits(.isHeader)
        .accessibilityFocused($isFocused)
        .onAppear { isFocused = true }
    }

    /// "Insulin on board, 2 of 3", or the title alone without a position.
    static func spokenLabel(title: String, position: String) -> String {
        position.isEmpty ? title : String(localized: "\(title), \(position)")
    }
}

// MARK: - Footer

/// What sits under a page: why the main button is off, when it is (where the eye goes to tap it), the main button
/// (Next, or the start's own), and Back, unless the page is the first.
struct SettingsTestPageFooter<Primary: View>: View {
    let blocker: String?
    let back: (() -> Void)?
    let primary: Primary

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(blocker: String?, back: (() -> Void)?, @ViewBuilder primary: () -> Primary) {
        self.blocker = blocker
        self.back = back
        self.primary = primary()
    }

    var body: some View {
        // At accessibility sizes the page says why at the end of its content (`SettingsTestPageBlocker`): pinned here,
        // its lines left a small phone's page almost no room.
        if let blocker, !dynamicTypeSize.isAccessibilitySize {
            SettingsTestPageBlocker.label(blocker)
        }
        primary
        if let back {
            Button("Back", action: back)
                .buttonStyle(.testSecondary)
        }
    }
}

/// Why a page's main button is off, at the end of the page's content, at accessibility sizes only: the footer says it at
/// other sizes (`SettingsTestPageFooter`).
struct SettingsTestPageBlocker: View {
    let blocker: String?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if let blocker, dynamicTypeSize.isAccessibilitySize {
            Self.label(blocker)
                .padding(.horizontal, 4)
        }
    }

    static func label(_ blocker: String) -> some View {
        Label {
            Text(blocker)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Choices

/// The glucose tablet brand, on one row: its label, and a menu of the brands with their grams a tablet, so the choice
/// takes one line of the page.
struct SettingsTestTabletBrandPicker: View {
    @Binding var selection: GlucoseTabletBrand

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            stacked
        } else {
            // On one line while the label and the choice fit beside each other. Where they don't (xxxLarge text with
            // Bold, or Display Zoom, on a small phone), one line broke "Brand" mid-word and cut the choice's wrapped
            // second line.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Brand")
                        .font(.body)
                    Spacer(minLength: 8)
                    // On one line: the label beside it is short, and a wrapped choice read as two.
                    menu(lines: 1)
                        .fixedSize()
                }
                stacked
            }
        }
    }

    /// The menu under the label, as wide as the card: at accessibility sizes the label and the longest choice don't fit
    /// one line.
    private var stacked: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Brand")
                .font(.body)
            menu(lines: nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The menu of brands with the choice as its label, as text that wraps and grows (unless held to `lines`): a menu
    /// picker's own label keeps one line's height, and at xxxLarge with Bold Text it wrapped inside the one-line row
    /// and was cut, so the row couldn't tell it no longer fit.
    private func menu(lines: Int?) -> some View {
        Menu {
            picker
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Self.label(for: selection))
                    .lineLimit(lines)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(Text("Brand, \(Self.label(for: selection))"))
    }

    private var picker: some View {
        Picker("Brand", selection: $selection) {
            ForEach(GlucoseTabletBrand.allCases) { brand in
                Text(Self.label(for: brand)).tag(brand)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }

    /// "Dex4, 4 g each".
    static func label(for brand: GlucoseTabletBrand) -> String {
        let grams = brand.carbsPerTablet.formatted(.number.precision(.fractionLength(0 ... 2)))
        return String(localized: "\(brand.displayName), \(grams) g each")
    }
}
