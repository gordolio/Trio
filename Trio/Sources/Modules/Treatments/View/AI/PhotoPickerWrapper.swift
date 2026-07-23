import AVFoundation
import AVKit
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

    func makeUIViewController(context: Context) -> UIViewController {
        switch sourceType {
        case .camera:
            let camera = FoodCameraViewController()
            camera.onCapture = { image in
                context.coordinator.didCapture(image)
            }
            camera.onCancel = {
                context.coordinator.didCancel()
            }
            return camera

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

        func didCapture(_ image: UIImage) {
            parent.selectedImage = image
            parent.isPresented = false
        }

        func didCancel() {
            parent.isPresented = false
        }

        func imagePickerController(
            _: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                didCapture(image)
            }
        }

        func imagePickerControllerDidCancel(_: UIImagePickerController) {
            didCancel()
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

/// Camera controller whose preview, scanner frame, and output crop share one coordinate space.
private final class FoodCameraViewController: UIViewController, AVCapturePhotoCaptureDelegate {
    var onCapture: ((UIImage) -> Void)?
    var onCancel: (() -> Void)?

    private let session = AVCaptureSession()
    private let captureOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "org.nightscout.trio.food-camera")
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private let overlayHost = UIHostingController(rootView: FoodScannerOverlayView())

    private var cameraInput: AVCaptureDeviceInput?
    private var cameraPosition: AVCaptureDevice.Position = .back
    private var isSessionConfigured = false
    private var isCapturing = false

    private lazy var shutterButton: UIButton = {
        let button = UIButton(type: .custom)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.backgroundColor = .white
        button.layer.cornerRadius = 38
        button.layer.borderWidth = 6
        button.layer.borderColor = UIColor.black.withAlphaComponent(0.75).cgColor
        button.accessibilityLabel = NSLocalizedString("Take Photo", comment: "Camera shutter accessibility label")
        button.accessibilityIdentifier = "food-camera-shutter"
        button.addTarget(self, action: #selector(capturePhoto), for: .touchUpInside)
        return button
    }()

    private lazy var cancelButton = makeControlButton(
        systemName: "xmark",
        accessibilityLabel: NSLocalizedString("Cancel", comment: "Dismiss camera accessibility label"),
        identifier: "food-camera-cancel",
        action: #selector(cancel)
    )

    private lazy var flipButton = makeControlButton(
        systemName: "arrow.triangle.2.circlepath.camera",
        accessibilityLabel: NSLocalizedString("Switch Camera", comment: "Switch camera accessibility label"),
        identifier: "food-camera-flip",
        action: #selector(flipCamera)
    )

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .black
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)

        addChild(overlayHost)
        overlayHost.view.translatesAutoresizingMaskIntoConstraints = false
        overlayHost.view.backgroundColor = .clear
        overlayHost.view.isUserInteractionEnabled = false
        view.addSubview(overlayHost.view)
        NSLayoutConstraint.activate([
            overlayHost.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlayHost.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlayHost.view.topAnchor.constraint(equalTo: view.topAnchor),
            overlayHost.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        overlayHost.didMove(toParent: self)

        view.addSubview(shutterButton)
        view.addSubview(cancelButton)
        view.addSubview(flipButton)

        NSLayoutConstraint.activate([
            shutterButton.widthAnchor.constraint(equalToConstant: 76),
            shutterButton.heightAnchor.constraint(equalTo: shutterButton.widthAnchor),
            shutterButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            shutterButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),

            cancelButton.widthAnchor.constraint(equalToConstant: 56),
            cancelButton.heightAnchor.constraint(equalTo: cancelButton.widthAnchor),
            cancelButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 32),
            cancelButton.centerYAnchor.constraint(equalTo: shutterButton.centerYAnchor),

            flipButton.widthAnchor.constraint(equalToConstant: 56),
            flipButton.heightAnchor.constraint(equalTo: flipButton.widthAnchor),
            flipButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -32),
            flipButton.centerYAnchor.constraint(equalTo: shutterButton.centerYAnchor)
        ])

        configureHardwareCapture()
        startCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds
        updateVideoRotation()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        let insets = view.safeAreaInsets
        overlayHost.rootView = FoodScannerOverlayView(
            safeAreaInsets: EdgeInsets(
                top: insets.top,
                leading: insets.left,
                bottom: insets.bottom,
                trailing: insets.right
            )
        )
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        sessionQueue.async { [session] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    private func makeControlButton(
        systemName: String,
        accessibilityLabel: String,
        identifier: String,
        action: Selector
    ) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: systemName)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        configuration.baseForegroundColor = .white
        configuration.baseBackgroundColor = UIColor.black.withAlphaComponent(0.55)
        configuration.cornerStyle = .capsule

        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = accessibilityLabel
        button.accessibilityIdentifier = identifier
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func configureHardwareCapture() {
        guard #available(iOS 17.2, *) else { return }

        // Preserve UIImagePickerController's hardware-shutter behavior.
        let interaction = AVCaptureEventInteraction { [weak self] event in
            guard event.phase == .ended else { return }
            self?.capturePhoto()
        }
        view.addInteraction(interaction)
    }

    private func startCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStartSession()

        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.configureAndStartSession()
                    } else {
                        self?.showCameraUnavailable()
                    }
                }
            }

        default:
            showCameraUnavailable()
        }
    }

    private func configureAndStartSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if !isSessionConfigured {
                session.beginConfiguration()
                session.sessionPreset = .photo

                do {
                    guard let device = cameraDevice(position: cameraPosition) else {
                        session.commitConfiguration()
                        DispatchQueue.main.async { self.showCameraUnavailable() }
                        return
                    }

                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input), session.canAddOutput(captureOutput) else {
                        session.commitConfiguration()
                        DispatchQueue.main.async { self.showCameraUnavailable() }
                        return
                    }

                    session.addInput(input)
                    session.addOutput(captureOutput)
                    captureOutput.maxPhotoQualityPrioritization = .quality
                    cameraInput = input
                    isSessionConfigured = true
                } catch {
                    session.commitConfiguration()
                    DispatchQueue.main.async { self.showCameraUnavailable() }
                    return
                }

                session.commitConfiguration()
            }

            if !session.isRunning {
                session.startRunning()
            }
        }
    }

    private func cameraDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    private var videoRotationAngle: CGFloat {
        switch view.window?.windowScene?.interfaceOrientation {
        case .landscapeLeft:
            return 0
        case .landscapeRight:
            return 180
        case .portraitUpsideDown:
            return 270
        default:
            return 90
        }
    }

    private func updateVideoRotation() {
        guard let connection = previewLayer.connection else { return }
        let angle = videoRotationAngle
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    @objc private func capturePhoto() {
        guard !isCapturing, session.isRunning else { return }
        isCapturing = true
        shutterButton.isEnabled = false

        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .quality

        if let device = cameraInput?.device, device.hasFlash {
            settings.flashMode = .auto
        }

        if let connection = captureOutput.connection(with: .video) {
            let angle = videoRotationAngle
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            if cameraPosition == .front, connection.isVideoMirroringSupported {
                connection.isVideoMirrored = true
            }
        }

        captureOutput.capturePhoto(with: settings, delegate: self)
    }

    @objc private func cancel() {
        onCancel?()
    }

    @objc private func flipCamera() {
        guard !isCapturing else { return }

        sessionQueue.async { [weak self] in
            guard let self, let currentInput = cameraInput else { return }

            let newPosition: AVCaptureDevice.Position = cameraPosition == .back ? .front : .back
            guard let device = cameraDevice(position: newPosition),
                  let newInput = try? AVCaptureDeviceInput(device: device)
            else { return }

            session.beginConfiguration()
            session.removeInput(currentInput)

            if session.canAddInput(newInput) {
                session.addInput(newInput)
                cameraInput = newInput
                cameraPosition = newPosition
            } else {
                session.addInput(currentInput)
            }

            session.commitConfiguration()
            DispatchQueue.main.async { self.updateVideoRotation() }
        }
    }

    func photoOutput(
        _: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        defer {
            isCapturing = false
            shutterButton.isEnabled = true
        }

        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data)
        else { return }

        let scanRegion = FoodScannerLayout.scanRegion(
            in: view.bounds.size,
            safeTop: view.safeAreaInsets.top,
            safeBottom: view.safeAreaInsets.bottom
        )

        guard let croppedImage = image.cropped(toPreviewRect: scanRegion, using: previewLayer) else {
            onCapture?(image)
            return
        }

        onCapture?(croppedImage)
    }

    private func showCameraUnavailable() {
        let alert = UIAlertController(
            title: NSLocalizedString("Camera Unavailable", comment: "Camera unavailable alert title"),
            message: NSLocalizedString(
                "Allow camera access in Settings, then try again.",
                comment: "Camera unavailable alert message"
            ),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: NSLocalizedString("Cancel", comment: "Dismiss camera alert"),
            style: .cancel
        ) { [weak self] _ in
            self?.onCancel?()
        })
        present(alert, animated: true)
    }
}

/// Extension to compress UIImage for API transmission
extension UIImage {
    fileprivate func cropped(
        toPreviewRect previewRect: CGRect,
        using previewLayer: AVCaptureVideoPreviewLayer
    ) -> UIImage? {
        let normalized = normalizedOrientation()
        guard let cgImage = normalized.cgImage else { return nil }

        let normalizedCropRect = previewLayer.metadataOutputRectConverted(fromLayerRect: previewRect)
        let imageBounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        let pixelCropRect = CGRect(
            x: normalizedCropRect.minX * imageBounds.width,
            y: normalizedCropRect.minY * imageBounds.height,
            width: normalizedCropRect.width * imageBounds.width,
            height: normalizedCropRect.height * imageBounds.height
        )
        .integral
        .intersection(imageBounds)

        guard !pixelCropRect.isEmpty,
              let cropped = cgImage.cropping(to: pixelCropRect)
        else { return nil }

        return UIImage(cgImage: cropped, scale: 1, orientation: .up)
    }

    private func normalizedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

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
