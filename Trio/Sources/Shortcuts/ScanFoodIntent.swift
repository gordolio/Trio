import AppIntents
import Foundation
import SwiftUI
import Swinject

@available(iOS 16.0, *) struct ScanFoodIntent: AppIntent {
    static var title = LocalizedStringResource("Scan Food with AI")
    static var description = IntentDescription(.init("Opens the camera to scan food in Trio"))
    static var openAppWhenRun: Bool = true

    @MainActor func perform() async throws -> some IntentResult {
        let resolver = TrioApp.resolver
        let router = resolver.resolve(Router.self)!

        // Present the camera as a SwiftUI sheet via the router's secondary modal
        let cameraView = ScanFoodCameraView(router: router)
        router.mainSecondaryModalView.send(AnyView(cameraView))

        return .result()
    }
}

/// Standalone camera view presented by the ScanFoodIntent shortcut.
/// When a photo is captured, it dismisses itself and opens the treatment view
/// with the image pre-loaded for AI analysis.
private struct ScanFoodCameraView: View {
    let router: Router
    @State private var selectedImage: UIImage?
    @State private var isPresented = true

    var body: some View {
        PhotoPickerWrapper(
            selectedImage: $selectedImage,
            isPresented: $isPresented,
            sourceType: .camera
        )
        .onChange(of: selectedImage) { _, newImage in
            guard let image = newImage,
                  let imageData = image.compressedForAI()
            else { return }

            // Dismiss the camera
            router.mainSecondaryModalView.send(nil)

            // Open treatments with the captured image pre-loaded
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                ScanFoodImageRelay.shared.pendingImageData = imageData
                router.mainModalScreen.send(.treatmentView)
            }
        }
        .onChange(of: isPresented) { _, presented in
            if !presented {
                router.mainSecondaryModalView.send(nil)
            }
        }
    }
}

/// Simple relay to pass captured image data from the shortcut camera to the treatment view.
final class ScanFoodImageRelay {
    static let shared = ScanFoodImageRelay()
    var pendingImageData: Data?
}

extension Notification.Name {
    static let openFoodScanner = Notification.Name("openFoodScanner")
}
