import SwiftUI

extension CarbRatioCalibration {
    struct CalibrationProgressBar: View {
        let currentStep: Step

        private let circleSize: CGFloat = 32

        var body: some View {
            ZStack(alignment: .top) {
                // Connector lines — centered vertically on the circles
                HStack(spacing: 0) {
                    ForEach(Array(Step.allCases.enumerated()), id: \.element) { index, step in
                        if index > 0 {
                            Rectangle()
                                .fill(step.rawValue <= currentStep.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                                .frame(height: 2)
                        }

                        // Invisible spacer matching the circle width
                        Color.clear
                            .frame(width: circleSize, height: circleSize)
                    }
                }

                // Step indicators (circles + labels)
                HStack(spacing: 0) {
                    ForEach(Array(Step.allCases.enumerated()), id: \.element) { index, step in
                        if index > 0 {
                            Spacer()
                        }

                        stepIndicator(for: step)
                    }
                }
            }
            .padding(.vertical, 12)
        }

        @ViewBuilder private func stepIndicator(for step: Step) -> some View {
            let isCompleted = step.rawValue < currentStep.rawValue
            let isCurrent = step == currentStep

            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(backgroundColor(isCompleted: isCompleted, isCurrent: isCurrent))
                        .frame(width: circleSize, height: circleSize)

                    if isCompleted {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                    } else {
                        Image(systemName: step.iconName)
                            .font(.system(size: 14))
                            .foregroundColor(isCurrent ? .white : .secondary)
                    }
                }

                Text(step.title)
                    .font(.caption2)
                    .foregroundColor(isCurrent ? .primary : .secondary)
                    .lineLimit(1)
            }
        }

        private func backgroundColor(isCompleted: Bool, isCurrent: Bool) -> Color {
            if isCompleted {
                return .green
            } else if isCurrent {
                return .accentColor
            } else {
                return Color.secondary.opacity(0.2)
            }
        }
    }
}

#Preview {
    VStack(spacing: 40) {
        CarbRatioCalibration.CalibrationProgressBar(currentStep: .preflight)
        CarbRatioCalibration.CalibrationProgressBar(currentStep: .prep)
        CarbRatioCalibration.CalibrationProgressBar(currentStep: .test)
        CarbRatioCalibration.CalibrationProgressBar(currentStep: .observation)
        CarbRatioCalibration.CalibrationProgressBar(currentStep: .results)
    }
    .padding()
}
