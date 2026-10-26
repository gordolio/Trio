import Charts
import SwiftUI

// Shared building blocks for the guided settings tests, styled like the rest of Trio:
// the app's gradient background, `Color.chart` cards, and its tint.

// MARK: - Screen

/// A test screen with Trio's background, scrolling content and a pinned action area.
struct SettingsTestScreen<Content: View, Footer: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    private let content: Content
    private let footer: Footer

    init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
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
        .background(appState.trioBackgroundColor(for: colorScheme).ignoresSafeArea())
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
    init(@ViewBuilder content: () -> Content) {
        self.init(content: content, footer: { EmptyView() })
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

            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

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

    var icon: String {
        switch self {
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .pending: return "circle.dotted"
        }
    }

    var color: Color {
        switch self {
        case .passed: return .green
        case .failed: return .red
        case .pending: return .secondary
        }
    }
}

struct SettingsTestCheckRow: View {
    let title: String
    let detail: String
    let state: SettingsTestCheckState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: state.icon)
                .font(.title3)
                .foregroundStyle(state.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
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

struct SettingsTestPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                Color.accentColor.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
    }
}

struct SettingsTestSecondaryButtonStyle: ButtonStyle {
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(destructive ? Color.red : Color.accentColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                Color.chart.opacity(configuration.isPressed ? 0.7 : 1),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
    }
}

extension ButtonStyle where Self == SettingsTestPrimaryButtonStyle {
    static var testPrimary: SettingsTestPrimaryButtonStyle { .init() }
}

extension ButtonStyle where Self == SettingsTestSecondaryButtonStyle {
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
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())
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

    /// "1:05:09" clock style, for countdowns.
    static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
