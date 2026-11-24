import CoreGraphics
import Testing
import UIKit

@testable import Trio

@Suite("Food camera crop") struct FoodCameraCropTests {
    private enum Color: Equatable {
        case red
        case green
        case blue
        case other
    }

    /// Like a camera photo: the stored pixels are 4×2 landscape, and the orientation says how to turn them
    /// for display (AVCapturePhotoOutput records its rotation angle as an Exif orientation).
    /// Stored column 0 is red on top and green below; the rest is blue.
    private func photo(orientation: UIImage.Orientation) -> UIImage {
        let width = 4, height = 2
        var bytes: [UInt8] = []
        for y in 0 ..< height {
            for x in 0 ..< width {
                switch (x, y) {
                case (0, 0): bytes += [255, 0, 0, 255]
                case (0, _): bytes += [0, 255, 0, 255]
                default: bytes += [0, 0, 255, 255]
                }
            }
        }
        let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        return UIImage(cgImage: cgImage, scale: 1, orientation: orientation)
    }

    /// Colours of an upright image's pixels, row by row, left to right.
    private func colors(of image: UIImage) -> [Color] {
        let cgImage = image.cgImage!
        let width = cgImage.width, height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 0, to: bytes.count, by: 4).map { i in
            switch (bytes[i] > 200, bytes[i + 1] > 200, bytes[i + 2] > 200) {
            case (true, false, false): return .red
            case (false, true, false): return .green
            case (false, false, true): return .blue
            default: return .other
            }
        }
    }

    @Test("Crops the stored pixels, then turns the result upright") func cropsBeforeTurning() throws {
        // Turned a quarter turn clockwise, stored column 0 becomes the top row, read bottom to top.
        let cropped = try #require(photo(orientation: .right).cropped(toSensorRect: CGRect(x: 0, y: 0, width: 0.25, height: 1)))

        #expect(cropped.imageOrientation == .up)
        #expect(cropped.size == CGSize(width: 2, height: 1))
        #expect(colors(of: cropped) == [.green, .red])
    }

    @Test("An upright photo crops as stored, top down") func uprightPhoto() throws {
        let cropped = try #require(photo(orientation: .up).cropped(toSensorRect: CGRect(x: 0, y: 0, width: 0.25, height: 0.5)))

        #expect(cropped.size == CGSize(width: 1, height: 1))
        #expect(colors(of: cropped) == [.red])
    }
}
