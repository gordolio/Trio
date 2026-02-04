import PhotosUI
import SwiftUI

/// Source type for photo selection
enum PhotoSourceType {
    case camera
    case photoLibrary
}

/// SwiftUI wrapper for presenting photo picker (camera or photo library)
struct PhotoPickerWrapper: UIViewControllerRepresentable {
    @Binding var selectedImage: UIImage?
    @Binding var isPresented: Bool
    let sourceType: PhotoSourceType
    var overlayBottomInset: CGFloat = 210

    func makeUIViewController(context: Context) -> UIViewController {
        switch sourceType {
        case .camera:
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.delegate = context.coordinator

            // Scale the camera preview to fill the screen (eliminates the black bar)
            let screenBounds = UIScreen.main.bounds
            let cameraAspectRatio: CGFloat = 4.0 / 3.0
            let previewHeight = screenBounds.width * cameraAspectRatio
            let scale = screenBounds.height / previewHeight
            picker.cameraViewTransform = CGAffineTransform(scaleX: scale, y: scale)

            // Add the food scanner overlay on top of the camera
            let overlayHost = UIHostingController(rootView: FoodScannerOverlayView(bottomInset: overlayBottomInset))
            overlayHost.view.backgroundColor = .clear
            overlayHost.view.isUserInteractionEnabled = false
            overlayHost.view.frame = screenBounds
            picker.cameraOverlayView = overlayHost.view

            return picker

        case .photoLibrary:
            var config = PHPickerConfiguration()
            config.filter = .images
            config.selectionLimit = 1
            let picker = PHPickerViewController(configuration: config)
            picker.delegate = context.coordinator
            return picker
        }
    }

    func updateUIViewController(_: UIViewController, context _: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate, PHPickerViewControllerDelegate {
        let parent: PhotoPickerWrapper

        init(_ parent: PhotoPickerWrapper) {
            self.parent = parent
        }

        // MARK: - UIImagePickerControllerDelegate (Camera)

        func imagePickerController(
            _: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.selectedImage = image
            }
            parent.isPresented = false
        }

        func imagePickerControllerDidCancel(_: UIImagePickerController) {
            parent.isPresented = false
        }

        // MARK: - PHPickerViewControllerDelegate (Photo Library)

        func picker(_: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.isPresented = false

            guard let result = results.first else { return }

            if result.itemProvider.canLoadObject(ofClass: UIImage.self) {
                result.itemProvider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
                    if let image = object as? UIImage {
                        DispatchQueue.main.async {
                            self?.parent.selectedImage = image
                        }
                    }
                }
            }
        }
    }
}

/// Extension to compress UIImage for API transmission
extension UIImage {
    /// Compresses the image to JPEG data with specified quality and maximum dimension
    /// - Parameters:
    ///   - quality: JPEG compression quality (0.0 to 1.0)
    ///   - maxDimension: Maximum width or height in pixels
    /// - Returns: Compressed JPEG data, or nil if compression fails
    func compressedForAI(quality: CGFloat = 0.7, maxDimension: CGFloat = 1024) -> Data? {
        let scaledImage: UIImage
        let currentMaxDimension = max(size.width, size.height)

        if currentMaxDimension > maxDimension {
            let scale = maxDimension / currentMaxDimension
            let newSize = CGSize(width: size.width * scale, height: size.height * scale)

            UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
            draw(in: CGRect(origin: .zero, size: newSize))
            scaledImage = UIGraphicsGetImageFromCurrentImageContext() ?? self
            UIGraphicsEndImageContext()
        } else {
            scaledImage = self
        }

        return scaledImage.jpegData(compressionQuality: quality)
    }
}
