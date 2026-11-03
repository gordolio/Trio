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

struct SettingsTestStepBar<Step: SettingsTestStep>: View where Step.AllCases: RandomAccessCollection {
    let current: Step

    private let circle: CGFloat = 30

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(Step.allCases.enumerated()), id: \.offset) { index, step in
                if index > 0 {
                    Rectangle()
                        .fill(step.order <= current.order ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(height: 2)
                        .padding(.bottom, 16)
                }
                indicator(for: step)
            }
        }
        .padding(.horizontal, 4)
    }

    private func indicator(for step: Step) -> some View {
        let done = step.order < current.order
        let isCurrent = step == current
        return VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : isCurrent ? Color.accentColor : Color.secondary.opacity(0.2))
                    .frame(width: circle, height: circle)
                Image(systemName: done ? "checkmark" : step.iconName)
                    .font(.system(size: 13, weight: done ? .bold : .regular))
                    .foregroundStyle(done || isCurrent ? Color.white : Color.secondary)
            }
            Text(step.title)
                .font(.caption2)
                .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                .lineLimit(1)
                .fixedSize()
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

    var icon: String {
        switch self {
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .pending: return "circle.dotted"
        case .info: return "info.circle"
        }
    }

    var color: Color {
        switch self {
        case .passed: return .green
        case .failed: return .red
        case .pending: return .secondary
        case .info: return .secondary
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

    var body: some View {
        SettingsTestInfoButton(info: info) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(value)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(value)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.subheadline)
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
                // The app has its own `Link` view modifier, so the SwiftUI one has to be named.
                SwiftUI.Link(link.title, destination: link.url)
                    .font(.subheadline.weight(.medium))
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

struct SettingsTestMetricRow: View {
    let metrics: [SettingsTestMetric]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                if index > 0 {
                    Divider().frame(height: 36)
                }
                VStack(spacing: 4) {
                    Text(metric.value)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    Text(metric.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Buttons

/// Upstream's Treatments button colours: system blue when it can be tapped, system grey when it can't.
struct SettingsTestPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                Color(uiColor: isEnabled ? .systemBlue : .systemGray).opacity(configuration.isPressed ? 0.8 : 1),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
    }
}

/// A full-width bordered button, like upstream's "Got it!" buttons (`PopupView`, `SettingInputHintView`), so it reads
/// as a button on the footer's bar and not as a link.
struct SettingsTestSecondaryButtonStyle: PrimitiveButtonStyle {
    var destructive = false

    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        Button(role: destructive ? .destructive : configuration.role, action: configuration.trigger) {
            configuration.label
                .fontWeight(.bold)
                .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.bordered)
        // On the light footer bar the bordered grey all but disappears, so in light mode the fill takes the tint, as
        // upstream's tinted bordered buttons do. Dark mode keeps the grey, which shows.
        .tint(destructive ? .red : colorScheme == .light ? Color.accentColor : nil)
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

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Chart {
            if let band {
                RectangleMark(
                    yStart: .value("Low", band.lowerBound.valueForChart(units)),
                    yEnd: .value("High", band.upperBound.valueForChart(units))
                )
                .foregroundStyle(Color.green.opacity(0.12))
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
        .frame(height: 160)
        .accessibilityLabel(Text("Glucose over the test"))
    }

    private var yDomain: ClosedRange<Double> {
        let values = points.map(\.glucose) + (band.map { [$0.lowerBound, $0.upperBound] } ?? [])
        let low = max(40, (values.min() ?? 70) - 10)
        let high = min(400, (values.max() ?? 180) + 10)
        return low.valueForChart(units) ... high.valueForChart(units)
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
