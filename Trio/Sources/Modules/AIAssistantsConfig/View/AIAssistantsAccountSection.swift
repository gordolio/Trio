import SwiftUI

extension AIAssistantsConfig {
    /// Who Trio is signed in as, and whether sharing works.
    struct AccountSection: View {
        @ObservedObject var state: StateModel

        /// Grows with Dynamic Type so the initials keep fitting.
        @ScaledMetric(relativeTo: .headline) private var avatarSize: CGFloat = 40
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize

        var body: some View {
            Section(header: Text("Account")) {
                accountRow
                if let status = state.sharingStatus {
                    statusRow(status)
                }
            }
            .listRowBackground(Color.chart)
        }

        /// At accessibility text sizes the avatar sits above the email, so the email keeps the width.
        private var accountRow: some View {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            avatar
                            Spacer()
                            appleGlyph
                        }
                        accountText
                    }
                } else {
                    HStack(spacing: 12) {
                        avatar
                        accountText
                        Spacer(minLength: 8)
                        appleGlyph
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.account?.email.map { Text("Signed in as \($0)") } ?? Text("Signed in with Apple"))
        }

        private var accountText: some View {
            VStack(alignment: .leading, spacing: 2) {
                if state.account?.email != nil {
                    Text("Signed in as")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(state.accountTitle)
            }
        }

        private var appleGlyph: some View {
            Image(systemName: "applelogo")
                .foregroundStyle(.secondary)
        }

        private var avatar: some View {
            Circle()
                .fill(Color.gray.gradient)
                .frame(width: avatarSize, height: avatarSize)
                .overlay {
                    Group {
                        if let initials = state.initials {
                            Text(initials)
                        } else {
                            Image(systemName: "person.fill")
                        }
                    }
                    .font(.system(size: avatarSize * 0.4, weight: .semibold))
                    .foregroundStyle(.white)
                }
        }

        private func statusRow(_ status: SharingStatus) -> some View {
            HStack(spacing: 12) {
                StatusDot(color: color(for: status))
                    .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : avatarSize)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(for: status))
                    if let lastUpload = lastUpload(for: status) {
                        TimelineView(.periodic(from: .now, by: 15)) { context in
                            Text(StateModel.updatedText(lastUpload: lastUpload, now: context.date))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }

        private func title(for status: SharingStatus) -> String {
            switch status {
            case .sharing: return String(localized: "Sharing with assistants")
            case .waitingForFirstUpdate: return String(localized: "Waiting for the first update")
            case let .failed(message, _): return message
            }
        }

        private func color(for status: SharingStatus) -> Color {
            switch status {
            case .sharing: return .loopGreen
            case .waitingForFirstUpdate: return .secondary
            case .failed: return .loopYellow
            }
        }

        private func lastUpload(for status: SharingStatus) -> Date? {
            switch status {
            case let .sharing(lastUpload): return lastUpload
            case .waitingForFirstUpdate: return nil
            case let .failed(_, lastUpload): return lastUpload
            }
        }
    }
}
