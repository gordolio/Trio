import CoreGraphics
import Testing
import UIKit

@testable import Trio

@Suite("Food camera crop") struct FoodCameraCropTests {
    private static let red: [UInt8] = [255, 0, 0, 255]
    private static let blue: [UInt8] = [0, 0, 255, 255]

    /// Like a camera photo: the stored pixels are 4×2 landscape, and the orientation says to turn them
    /// a quarter turn clockwise for display, as AVCapturePhotoOutput's Exif tag does at a 90° rotation angle.
    /// Stored column 0 is red; the rest is blue.
    private func photo(orientation: UIImage.Orientation) -> UIImage {
        let width = 4, height = 2
        var bytes: [UInt8] = []
        for _ in 0 ..< height {
            for x in 0 ..< width {
                bytes += x == 0 ? Self.red : Self.blue
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

    /// RGBA pixels of an upright image, row by row.
    private func pixels(of image: UIImage) -> [[UInt8]] {
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
        return stride(from: 0, to: bytes.count, by: 4).map { Array(bytes[$0 ..< $0 + 4]) }
    }

    private func isRed(_ pixel: [UInt8]) -> Bool {
        pixel[0] > 200 && pixel[1] < 50 && pixel[2] < 50
    }

    @Test("Crops the stored pixels, then turns the result upright") func cropsBeforeTurning() throws {
        // Stored column 0 is the top row once the photo is turned upright.
        let cropped = try #require(photo(orientation: .right).cropped(toSensorRect: CGRect(x: 0, y: 0, width: 0.25, height: 1)))

        #expect(cropped.imageOrientation == .up)
        #expect(cropped.size == CGSize(width: 2, height: 1))
        #expect(pixels(of: cropped).allSatisfy(isRed))
    }

    @Test("An upright photo crops as stored") func uprightPhoto() throws {
        let cropped = try #require(photo(orientation: .up).cropped(toSensorRect: CGRect(x: 0, y: 0, width: 0.25, height: 1)))

        #expect(cropped.size == CGSize(width: 1, height: 2))
        #expect(pixels(of: cropped).allSatisfy(isRed))
    }
}
