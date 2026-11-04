import Charts
import SwiftUI

// Shared building blocks for the guided settings tests, styled like the rest of Trio:
// the app's gradient background, `Color.chart` cards, and its tint.

// MARK: - Screen

/// A test screen with scrolling content and a pinned action area, on Trio's background unless the screen it sits in
/// paints that already.
struct SettingsTestScreen<Content: View, Footer: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    private let paintsBackground: Bool
    private let content: Content
    private let footer: Footer

    /// `paintsBackground` is false inside a view that paints Trio's background itself, such as a wizard's layout or a
    /// sheet: the light background is a translucent grey, so painting it twice darkens it.
    init(paintsBackground: Bool = true, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.paintsBackground = paintsBackground
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
        .background {
            if paintsBackground {
                appState.trioBackgroundColor(for: colorScheme).ignoresSafeArea()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if Footer.self != EmptyView.self {
                VStack(spacing: 10) {
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
    }
}

extension SettingsTestScreen where Footer == EmptyView {
    init(paintsBackground: Bool = true, @ViewBuilder content: () -> Content) {
        self.init(paintsBackground: paintsBackground, content: content, footer: { EmptyView() })
    }
}

// MARK: - Card

struct SettingsTestCard<Content: View>: View {
    private let title: String?
    private let content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(.headline)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.chart, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Header

struct SettingsTestHeader: View {
    let icon: String
    let title: String
    let subtitle: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 64, height: 64)
                .background(tint.opacity(0.15), in: Circle())
                .accessibilityHidden(true)

            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }
}

// MARK: - Step bar

/// A step in a test's flow, shown in `SettingsTestStepBar`.
protocol SettingsTestStep: Hashable, CaseIterable {
    var title: String { get }
    var iconName: String { get }
    var order: Int { get }
}

/// How the step bar shows a step.
enum SettingsTestStepStatus: Equatable {
    /// Before the current step, and it happened: a green check.
    case done
    case current
    /// Before the current step, but the test went past it without doing it: a grey dash, never the green check.
    case skipped
    /// Still to come.
    case upcoming
}

struct SettingsTestStepBar<Step: SettingsTestStep>: View where Step.AllCases: RandomAccessCollection {
    let current: Step
    /// Steps the test went past without doing, e.g. a step it didn't need. Only steps before the current one show it.
    var skipped: Set<Step> = []

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let circle: CGFloat = 30

    /// How `step` shows while the test is at `current`: a step before it is done unless it was skipped.
    static func status(of step: Step, current: Step, skipped: Set<Step>) -> SettingsTestStepStatus {
        if step == current { return .current }
        guard step.order < current.order else { return .upcoming }
        return skipped.contains(step) ? .skipped : .done
    }

    var body: some View {
        // At accessibility sizes five titles don't fit in a row, so the circles stand alone and the current step's
        // title is said once, under them.
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 6) {
                bar(showsTitles: false)
                Text(current.title)
                    .font(.caption2)
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    // Each circle already says its step.
                    .accessibilityHidden(true)
            }
        } else {
            bar(showsTitles: true)
        }
    }

    private func bar(showsTitles: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(Step.allCases.enumerated()), id: \.offset) { index, step in
                if index > 0 {
                    Rectangle()
                        .fill(step.order <= current.order ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(height: 2)
                        // Level with the circles' centres, above the titles under them.
                        .padding(.bottom, showsTitles ? 16 : 0)
                }
                indicator(for: step, showsTitle: showsTitles)
            }
        }
        .padding(.horizontal, 4)
    }

    private func indicator(for step: Step, showsTitle: Bool) -> some View {
        let status = Self.status(of: step, current: current, skipped: skipped)
        return VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(fill(for: status))
                    .frame(width: circle, height: circle)
                Image(systemName: icon(for: step, status: status))
                    .font(.system(size: 13, weight: status == .done || status == .skipped ? .bold : .regular))
                    .foregroundStyle(status == .upcoming ? Color.secondary : Color.white)
            }
            if showsTitle {
                Text(step.title)
                    .font(.caption2)
                    .foregroundStyle(status == .current ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(step.title))
        .accessibilityValue(Text(spokenStatus(status)))
    }

    private func fill(for status: SettingsTestStepStatus) -> Color {
        switch status {
        case .done: return .green
        case .current: return .accentColor
        // Solid like a done step, so it reads as passed, but neutral, so it never reads as a check.
        case .skipped: return Color(uiColor: .systemGray)
        case .upcoming: return Color.secondary.opacity(0.2)
        }
    }

    private func icon(for step: Step, status: SettingsTestStepStatus) -> String {
        switch status {
        case .done: return "checkmark"
        case .skipped: return "minus"
        case .current,
             .upcoming: return step.iconName
        }
    }

    private func spokenStatus(_ status: SettingsTestStepStatus) -> String {
        switch status {
        case .done: return String(localized: "Done")
        case .current: return String(localized: "Current step")
        case .skipped: return String(localized: "Skipped")
        case .upcoming: return String(localized: "Not started")
        }
    }
}

// MARK: - Check row

enum SettingsTestCheckState {
    case passed
    case failed
    case pending
    /// Neither a pass nor a fail: something the user should know.
    case info
    /// Still only informs and never blocks, but is easy to miss and worth a look before starting.
    case warning

    var icon: String {
        switch self {
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .pending: return "circle.dotted"
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .passed: return .green
        case .failed: return .red
        case .pending: return .secondary
        case .info: return .secondary
        case .warning: return .orange
        }
    }
}

/// A check that passes or fails: its state icon, a title and, when it says more than the title, a detail.
struct SettingsTestCheckRow: View {
    let title: String
    let detail: String?
    let state: SettingsTestCheckState
    /// When set, the row shows a blue info button and tapping it opens a sheet with the explanation.
    var info: SettingsTestInfo?

    var body: some View {
        SettingsTestInfoButton(info: info) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: state.icon)
                    .font(.title3)
                    .foregroundStyle(state.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    if let detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// A reading that sets no rule, on one line: the label on the left and the value on the right, like a settings row.
/// Its longer explanation is in the info sheet.
struct SettingsTestValueRow: View {
    let title: String
    let value: String
    var info: SettingsTestInfo?
    /// `.warning` puts its orange triangle before the title, for a reading that is easy to miss. The row still only
    /// informs. Any other state shows nothing extra.
    var state: SettingsTestCheckState = .info

    var body: some View {
        SettingsTestInfoButton(info: info) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    titleLabel
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(value)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    titleLabel
                    Text(value)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.subheadline)
        }
    }

    @ViewBuilder private var titleLabel: some View {
        if state == .warning {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: state.icon)
                    .foregroundStyle(state.color)
                    .accessibilityLabel(Text("Warning"))
                Text(title)
            }
        } else {
            Text(title)
        }
    }
}

/// Makes a row open its info sheet, with upstream's blue `info.circle` at the trailing edge as the visible button
/// (the Treatments "Recommendation" pattern). The whole row stays tappable, for a bigger target.
private struct SettingsTestInfoButton<RowContent: View>: View {
    let info: SettingsTestInfo?
    @ViewBuilder let label: () -> RowContent

    @State private var isShowingInfo = false

    var body: some View {
        if let info {
            Button {
                isShowingInfo = true
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    label()
                    Image(systemName: "info.circle")
                        .font(.body)
                        .foregroundStyle(Color.blue)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Shows more information"))
            .sheet(isPresented: $isShowingInfo) {
                SettingsTestInfoSheet(info: info)
            }
        } else {
            label()
                .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Docs

/// A passage from the Trio docs, word for word: in primary text beside a thin accent bar, under a small caption, so
/// the docs read first and the app's own words come after them.
struct SettingsTestDocsQuote: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Trio docs")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 13)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.accentColor)
                .frame(width: 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A named link to a Trio docs page. The name says which page, so two links on one screen can be told apart.
struct SettingsTestDocsLink: Identifiable {
    let id = UUID()
    let title: String
    let url: URL
}

struct SettingsTestDocsLinks: View {
    let links: [SettingsTestDocsLink]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(links) { link in
                // The app has its own `Link` view modifier, so the SwiftUI one has to be named. A link centres the lines
                // of a title it lays out itself, so the title is a label of its own that runs from the leading edge on
                // every line, like the card's text.
                SwiftUI.Link(destination: link.url) {
                    Text(link.title)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Metrics

struct SettingsTestMetric: Identifiable {
    let id = UUID()
    let title: String
    let value: String
}

/// Values side by side with their titles under them, e.g. Start, Now and Change. At accessibility sizes a third of the
/// card is too narrow for a title, which broke inside its word ("Chang" "e"), so the items stack, one to a line, a title
/// and its value on the same line when they fit side by side and otherwise the value over the title.
struct SettingsTestMetricRow: View {
    let metrics: [SettingsTestMetric]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            // One layout for every item, so they stay aligned.
            ViewThatFits(in: .horizontal) {
                stacked(titleBesideValue: true)
                stacked(titleBesideValue: false)
            }
        } else {
            columns
        }
    }

    private var columns: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                if index > 0 {
                    Divider().frame(height: 36)
                }
                VStack(spacing: 4) {
                    value(of: metric)
                    title(of: metric)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func stacked(titleBesideValue: Bool) -> some View {
        VStack(spacing: 8) {
            ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                if index > 0 {
                    Divider()
                }
                if titleBesideValue {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        title(of: metric)
                        Spacer(minLength: 0)
                        value(of: metric)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        value(of: metric)
                        title(of: metric)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func value(of metric: SettingsTestMetric) -> some View {
        Text(metric.value)
            .font(.title3.weight(.semibold))
            .monospacedDigit()
            .minimumScaleFactor(0.7)
            .lineLimit(1)
    }

    private func title(of metric: SettingsTestMetric) -> some View {
        Text(metric.title)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Buttons

/// Upstream's Treatments blue when it can be tapped. When it can't, a neutral system fill with grey text: grey reads
/// as off, and a blue that can't be tapped looked like the secondary button under it.
struct SettingsTestPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(isEnabled ? Color.white : disabledText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                isEnabled
                    ? Color(uiColor: .systemBlue).opacity(configuration.isPressed ? 0.8 : 1)
                    : Color(uiColor: .tertiarySystemFill),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
    }

    /// In dark mode a step dimmer, because the secondary grey there is brighter than the secondary button's blue text.
    private var disabledText: Color {
        Color(uiColor: colorScheme == .dark ? .tertiaryLabel : .secondaryLabel)
    }
}

/// A full-width bordered button, like upstream's "Got it!" buttons (`PopupView`, `SettingInputHintView`), so it reads
/// as a button on the footer's bar and not as a link.
struct SettingsTestSecondaryButtonStyle: PrimitiveButtonStyle {
    var destructive = false

    @Environment(\.isEnabled) private var isEnabled

    /// The text of a secondary button that can be tapped: a darker blue than the tint in light mode (the system's
    /// increased-contrast blue) and a lighter one in dark mode, so it reads at 4.5:1 or more on the tinted fill. The
    /// tint itself measured about 2.8:1 in light mode and 4.3:1 in dark; these about 5.9:1 and 6.1:1.
    static var textColor: UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 100 / 255, green: 175 / 255, blue: 1, alpha: 1)
                : UIColor(red: 0, green: 64 / 255, blue: 221 / 255, alpha: 1)
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        Button(role: destructive ? .destructive : configuration.role, action: configuration.trigger) {
            label(configuration)
                .fontWeight(.bold)
                .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.bordered)
        // The fill takes the tint, as upstream's tinted bordered buttons do: untinted, the bordered grey all but
        // disappears on the light footer bar and is near black on the dark one.
        .tint(destructive ? .red : Color.accentColor)
    }

    /// The text in `textColor`, except where the system's own colour says more: a destructive button's red, and the
    /// greyed text of one that can't be tapped.
    @ViewBuilder private func label(_ configuration: Configuration) -> some View {
        if destructive || !isEnabled {
            configuration.label
        } else {
            configuration.label
                .foregroundStyle(Color(uiColor: Self.textColor))
        }
    }
}

extension ButtonStyle where Self == SettingsTestPrimaryButtonStyle {
    static var testPrimary: SettingsTestPrimaryButtonStyle { .init() }
}

extension PrimitiveButtonStyle where Self == SettingsTestSecondaryButtonStyle {
    static var testSecondary: SettingsTestSecondaryButtonStyle { .init() }
    static var testDestructive: SettingsTestSecondaryButtonStyle { .init(destructive: true) }
}

// MARK: - Progress

struct SettingsTestProgressBar: View {
    /// 0...1
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: proxy.size.width * min(1, max(0, progress)))
                    .animation(.linear(duration: 1), value: progress)
            }
        }
        .frame(height: 8)
    }
}

// MARK: - Glucose chart

struct SettingsTestGlucosePoint: Identifiable, Equatable {
    var id: Date { date }
    let date: Date
    /// mg/dL
    let glucose: Int
}

struct SettingsTestGlucoseChart: View {
    let points: [SettingsTestGlucosePoint]
    let units: GlucoseUnits
    /// mg/dL band to shade, e.g. the range a test wants glucose to stay in.
    var band: ClosedRange<Int>?
    /// mg/dL to mark with a dashed line, e.g. the user's target. Secondary, so the glucose line stays the one in colour.
    var target: Int?
    /// The times to shade the band over, e.g. where a test's expected end applies. Nil shades it across the whole chart.
    var bandTimes: ClosedRange<Date>?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Chart {
            if let band, let bandTimes {
                // A small patch at the end of the chart, so a faint wash like the full-width band's doesn't show,
                // least of all in dark mode: a stronger fill and a thin outline. Drawn before the glucose line, which
                // stays on top of it.
                let low = band.lowerBound.valueForChart(units)
                let high = band.upperBound.valueForChart(units)
                RectangleMark(
                    xStart: .value("Time", bandTimes.lowerBound),
                    xEnd: .value("Time", bandTimes.upperBound),
                    yStart: .value("Low", low),
                    yEnd: .value("High", high)
                )
                .foregroundStyle(Color.green.opacity(0.3))
                // The outline, one side at a time: a band of one reading has its top and bottom on the same line.
                RuleMark(
                    xStart: .value("Time", bandTimes.lowerBound),
                    xEnd: .value("Time", bandTimes.upperBound),
                    y: .value("Low", low)
                )
                .foregroundStyle(Color.green)
                .lineStyle(StrokeStyle(lineWidth: 1))
                RuleMark(
                    xStart: .value("Time", bandTimes.lowerBound),
                    xEnd: .value("Time", bandTimes.upperBound),
                    y: .value("High", high)
                )
                .foregroundStyle(Color.green)
                .lineStyle(StrokeStyle(lineWidth: 1))
                RuleMark(x: .value("Time", bandTimes.lowerBound), yStart: .value("Low", low), yEnd: .value("High", high))
                    .foregroundStyle(Color.green)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                RuleMark(x: .value("Time", bandTimes.upperBound), yStart: .value("Low", low), yEnd: .value("High", high))
                    .foregroundStyle(Color.green)
                    .lineStyle(StrokeStyle(lineWidth: 1))
            } else if let band {
                RectangleMark(
                    yStart: .value("Low", band.lowerBound.valueForChart(units)),
                    yEnd: .value("High", band.upperBound.valueForChart(units))
                )
                .foregroundStyle(Color.green.opacity(0.12))
            }
            if let target {
                RuleMark(y: .value("Target", target.valueForChart(units)))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    .annotation(position: .top, alignment: .leading) {
                        // On the card's own colour, so the gridlines behind it don't run through the word.
                        Text("Target")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 3)
                            .background(Color.chart)
                    }
            }
            ForEach(points) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Glucose", point.glucose.valueForChart(units))
                )
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: yDomain)
        .chartXAxis {
            // Hours only, as upstream's forecast chart labels them, and fewer of them at accessibility sizes, so the
            // labels don't run into each other. The caption under the chart gives the exact times.
            AxisMarks(values: .stride(by: .hour, count: dynamicTypeSize.isAccessibilitySize ? 2 : 1)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .narrow)), anchor: .top)
            }
        }
        .fewerYAxisMarks(dynamicTypeSize.isAccessibilitySize)
        .frame(height: 160)
        .accessibilityLabel(Text("Glucose over the test"))
    }

    private var yDomain: ClosedRange<Double> {
        let range = Self.yRange(
            values: points.map(\.glucose) + (band.map { [$0.lowerBound, $0.upperBound] } ?? []),
            target: target
        )
        return range.lowerBound.valueForChart(units) ... range.upperBound.valueForChart(units)
    }

    /// The y range in mg/dL: the values and the target with 10 mg/dL either side, kept within 40–400. The target's
    /// label sits above its line, so above the target there is room for it too: a fifth of the range below it, and at
    /// least the 10 mg/dL. At least 10 mg/dL is always shown, so readings or a target all past one end of 40–400 still
    /// give a range: the 10 mg/dL at that end.
    static func yRange(values: [Int], target: Int?) -> ClosedRange<Int> {
        let all = values + (target.map { [$0] } ?? [])
        let low = min(390, max(40, (all.min() ?? 70) - 10))
        var high = (all.max() ?? 180) + 10
        if let target {
            high = max(high, target + max(10, (target - low) / 5))
        }
        return low ... max(low + 10, min(400, high))
    }
}

private extension View {
    /// At accessibility sizes the value labels of the y axis are tall, and the chart's 160 pt holds only a few of them
    /// before they touch, so it asks for 3 marks (grid line and value each) instead of the automatic ones. At other sizes
    /// the chart's own automatic marks stay as they are.
    @ViewBuilder func fewerYAxisMarks(_ fewer: Bool) -> some View {
        if fewer {
            chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
        } else {
            self
        }
    }
}

private extension Int {
    func valueForChart(_ units: GlucoseUnits) -> Double {
        units == .mgdL ? Double(self) : Double(truncating: asMmolL as NSNumber)
    }
}

// MARK: - Formatting

enum SettingsTestFormat {
    /// "1 h 05 m" style duration.
    static func duration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return String(format: "%d h %02d m", hours, minutes)
        }
        return "\(minutes) m"
    }

    /// The line passed checks fold into: all of them, or the ones that pass beside a check that doesn't.
    static func passedChecksSummary(passing: Int, total: Int) -> String {
        if passing == total {
            return String(localized: "All \(total) checks pass")
        }
        return passing == 1
            ? String(localized: "1 other check passes")
            : String(localized: "\(passing) other checks pass")
    }

    /// A value and its unit that never break across lines inside a sentence: a no-break space before the unit, and a
    /// word joiner after each slash in it, where a line could otherwise break ("72 mg/" … "dL").
    static func keepTogether(_ value: String, unit: String) -> String {
        "\(value)\u{00A0}\(unit.replacingOccurrences(of: "/", with: "/\u{2060}"))"
    }
}
