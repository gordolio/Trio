import SwiftUI
import Testing
import UIKit

@testable import Trio

/// Renders the AI Assistants screens in the test host, in every state, in light and dark mode.
/// Set `AI_ASSISTANTS_SCREENSHOTS_DIR` (with xcodebuild: `TEST_RUNNER_AI_ASSISTANTS_SCREENSHOTS_DIR`)
/// to a folder to also save each rendering there as a PNG.
@Suite("AI Assistants screen renders", .serialized) @MainActor struct AIAssistantsScreenRenderTests {
    static let screenshotsDirectory = ProcessInfo.processInfo.environment["AI_ASSISTANTS_SCREENSHOTS_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }

    @Test(
        "Every state renders in light and dark mode",
        arguments: AIAssistantsConfig.PreviewState.allCases
    ) func everyStateRenders(_ previewState: AIAssistantsConfig.PreviewState) async throws {
        for dark in [false, true] {
            let state = AIAssistantsConfig.previewStateModel(previewState)
            try await render(
                AIAssistantsConfig.ContentView(state: state),
                named: "\(previewState.rawValue)-\(dark ? "dark" : "light")",
                dark: dark
            )
        }
    }

    @Test(
        "Each assistant's setup screen renders in light and dark mode",
        arguments: AIAssistantsConfig.Assistant.allCases
    ) func setupScreenRenders(_ assistant: AIAssistantsConfig.Assistant) async throws {
        for dark in [false, true] {
            let state = AIAssistantsConfig.previewStateModel(.linked)
            try await render(
                AIAssistantsConfig.AssistantSetupView(assistant: assistant, state: state),
                named: "setup-\(assistant.rawValue)-\(dark ? "dark" : "light")",
                dark: dark,
                height: 1100
            )
        }
    }

    @Test("The linked screen renders at the largest text sizes") func linkedScreenRendersAtLargestText() async throws {
        let state = AIAssistantsConfig.previewStateModel(.linked)
        try await render(
            AIAssistantsConfig.ContentView(state: state).environment(\.dynamicTypeSize, .accessibility3),
            named: "linked-ax3-light",
            dark: false,
            height: 2700
        )
    }

    /// Lays `content` out in a window of the test host's scene, 402 pt wide (an iPhone 17), and
    /// draws it. Taller than about 2,700 pt (8,192 px at 3x) draws blank.
    private func render(_ content: some View, named name: String, dark: Bool, height: CGFloat = 2200) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: NavigationStack { content }.environment(AppState()))
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.frame = CGRect(x: 0, y: 0, width: 402, height: height)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(400))
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        #expect(distinctColorCount(in: image) > 1, "\(name) drew a blank image")
        if let directory = Self.screenshotsDirectory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try #require(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"))
        }
    }

    /// How many different colours a coarse grid of the image's pixels has.
    private func distinctColorCount(in image: UIImage) -> Int {
        guard let cgImage = image.cgImage, let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return 0 }
        var colors = Set<UInt32>()
        for row in stride(from: 0, to: cgImage.height, by: 40) {
            for column in stride(from: 0, to: cgImage.width, by: 40) {
                let offset = row * cgImage.bytesPerRow + column * cgImage.bitsPerPixel / 8
                colors.insert(UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]))
            }
        }
        return colors.count
    }
}
