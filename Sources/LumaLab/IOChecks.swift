import LumaDomain
import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum IOChecks {
    struct Failure: LocalizedError {
        let text: String
        var errorDescription: String? { "IO check failed: \(text)" }
    }
    static func run() throws -> String {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw Failure(text: message) }
            assertions += 1
        }
        let context = CIContext(options: [.cacheIntermediates: false])
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func bitmap(_ value: UInt8, width: Int = 16, height: Int = 12) -> CGImage {
            var pixels = [UInt8](repeating: value, count: width * height * 4)
            for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }
        func encoded(_ image: CGImage, type: UTType = .png, properties: [CFString: Any] = [:]) throws -> Data {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { throw Failure(text: "fixture destination") }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw Failure(text: "fixture encoding") }
            return data as Data
        }
        func values(_ image: CIImage) throws -> [UInt8] {
            guard let cg = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: space),
                  let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { throw Failure(text: "result render") }
            return Array(UnsafeBufferPointer(start: bytes, count: CFDataGetLength(data)))
        }
        let bmp = makeBMP(width: 16, height: 12)
        let decodedBMP = try PhotoIO.decode(data: bmp, fileExtension: "bmp")
        try check(decodedBMP.image.extent.size == CGSize(width: 16, height: 12), "BMP full dimensions")
        let bmpPixels = try values(decodedBMP.image)
        try check(bmpPixels[0] > 180 && bmpPixels[1] < 40, "BMP top-left color and orientation")
        try check(PhotoIO.supportedExtensions.contains("dng") && PhotoIO.supportedExtensions.contains("tiff") && PhotoIO.supportedExtensions.contains("bmp"), "format inventory")
        let metadataFixture: [String: Any] = [
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFMake as String: "Fixture Camera", kCGImagePropertyTIFFModel as String: "Test 1"],
            kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifExposureTime as String: 1.0 / 125, kCGImagePropertyExifFNumber as String: 4.0,
                kCGImagePropertyExifISOSpeedRatings as String: [100], kCGImagePropertyExifLensModel as String: "50 mm Fixture", kCGImagePropertyExifFocalLength as String: 50],
            kCGImagePropertyDepth as String: 16, kCGImagePropertyProfileName as String: "sRGB IEC61966-2.1"]
        let metadata = PhotoIO.extractMetadata(properties: metadataFixture, size: CGSize(width: 80, height: 60))
        try check(abs((metadata.exposureEV ?? -100) - log2(2000)) < 0.0001, "EXIF EV100")
        try check(metadata.rows.contains { $0.0 == "相机型号" && $0.1 == "Test 1" }, "camera metadata")
        try check(metadata.rows.contains { $0.0 == "镜头" && $0.1 == "50 mm Fixture" }, "lens metadata")
        try check(metadata.rows.contains { $0.0 == "位深" && $0.1 == "16" }, "bit depth metadata")
        try check(metadata.properties[kCGImagePropertyExifDictionary as String] != nil, "original properties retained")
        let oriented = try PhotoIO.decode(data: encoded(bitmap(100), type: .jpeg, properties: [kCGImagePropertyOrientation: 6]), fileExtension: "jpg")
        try check(oriented.image.extent.size == CGSize(width: 12, height: 16), "ImageIO EXIF orientation")
        var rejected = false
        do { _ = try PhotoIO.decode(data: Data("not an image".utf8), fileExtension: "png") } catch { rejected = true }
        try check(rejected, "invalid data rejected")
        rejected = false
        do { _ = try PhotoIO.decode(data: try encoded(bitmap(100)), fileExtension: "cr3") } catch { rejected = true }
        try check(rejected, "unsupported RAW does not silently use thumbnail")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LumaLab-IOChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func fixture(_ name: String, _ value: UInt8, width: Int = 16) throws -> URL {
            let url = directory.appendingPathComponent(name + ".png")
            try encoded(bitmap(value, width: width)).write(to: url)
            return url
        }
        let black = try fixture("black", 0), middle = try fixture("middle", 128), white = try fixture("white", 255)
        var progressValues: [Double] = []
        let average = try StackProcessor.combine(urls: [black, white], mode: .average, align: false) { progressValues.append($0) }
        let averagePixels = try values(average.image)
        try check(average.image.extent.size == CGSize(width: 16, height: 12), "stack preserves full dimensions")
        try check(abs(Int(averagePixels[0]) - 188) <= 3, "average is linear-light, not gamma-space midpoint")
        try check(progressValues.last == 1 && zip(progressValues, progressValues.dropFirst()).allSatisfy { $0 <= $1 }, "monotonic progress")
        let median = try StackProcessor.combine(urls: [black, middle, white], mode: .median, align: false)
        let medianPixels = try values(median.image)
        try check(abs(Int(medianPixels[0]) - 128) <= 3, "median suppresses bright and dark outliers")
        let trails = try StackProcessor.combine(urls: [black, middle, white], mode: .starTrails, align: false)
        let trailPixels = try values(trails.image)
        try check(trailPixels[0] >= 252 && trails.report.contains("星轨"), "star trails takes lighten maximum")
        let hdr = try StackProcessor.combine(urls: [middle, white], mode: .hdr, align: false)
        let hdrPixels = try values(hdr.image)
        try check(hdrPixels[0] > 0 && hdrPixels[0] <= 255 && hdr.report.contains("回退") && hdr.report.contains("标准动态范围"), "HDR missing-EXIF fallback disclosed")
        let mismatch = try fixture("mismatch", 100, width: 15)
        rejected = false
        do { _ = try StackProcessor.combine(urls: [black, mismatch], mode: .average, align: false) } catch StackProcessor.Failure.dimensions { rejected = true }
        try check(rejected, "mismatched dimensions rejected")
        rejected = false
        do { _ = try StackProcessor.combine(urls: [black], mode: .average, align: false) } catch { rejected = true }
        try check(rejected, "single source rejected")
        rejected = false
        do { _ = try StackProcessor.combine(urls: Array(repeating: black, count: 16), mode: .median, align: false) } catch { rejected = true }
        try check(rejected, "median count limit")
        let bmpURL = directory.appendingPathComponent("orientation.bmp")
        try bmp.write(to: bmpURL)
        let orientedStack = try StackProcessor.combine(urls: [bmpURL, bmpURL], mode: .average, align: false)
        let orientedPixels = try values(orientedStack.image)
        try check(orientedPixels[0] > 180 && orientedPixels[1] < 40, "stack keeps top-left orientation")
        let tiff = try PhotoIO.decode(data: encoded(bitmap(80), type: .tiff, properties: [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Fixture Camera"]]), fileExtension: "tiff")
        try check(tiff.metadata.rows.contains { $0.0 == "相机品牌" && $0.1 == "Fixture Camera" }, "TIFF metadata round trip")
        let exposureA = directory.appendingPathComponent("exposure-a.jpg"), exposureB = directory.appendingPathComponent("exposure-b.jpg")
        try encoded(bitmap(90), type: .jpeg, properties: [kCGImagePropertyExifDictionary: [kCGImagePropertyExifExposureTime: 1.0 / 125, kCGImagePropertyExifFNumber: 4.0, kCGImagePropertyExifISOSpeedRatings: [100]]]).write(to: exposureA)
        try encoded(bitmap(160), type: .jpeg, properties: [kCGImagePropertyExifDictionary: [kCGImagePropertyExifExposureTime: 1.0 / 60, kCGImagePropertyExifFNumber: 4.0, kCGImagePropertyExifISOSpeedRatings: [100]]]).write(to: exposureB)
        let calibratedHDR = try StackProcessor.combine(urls: [exposureA, exposureB], mode: .hdr, align: false)
        try check(!calibratedHDR.report.contains("回退") && calibratedHDR.report.contains("归一化曝光"), "HDR uses exposure EXIF when available")
        // Deterministic non-repeating texture gives registration an unambiguous target.
        var pattern = [UInt8](repeating: 255, count: 128 * 128 * 4)
        for y in 0..<128 { for x in 0..<128 {
            let value = UInt8((x * 73 + y * 37 + (x / 7) * (y / 9) * 29) % 210 + 20)
            let i = (y * 128 + x) * 4
            pattern[i] = value; pattern[i + 1] = value; pattern[i + 2] = value
        } }
        let patternImage = CGImage(width: 128, height: 128, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 128 * 4, space: space,
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                   provider: CGDataProvider(data: Data(pattern) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let referenceURL = directory.appendingPathComponent("align-reference.png"), shiftedURL = directory.appendingPathComponent("align-shifted.png")
        try encoded(patternImage).write(to: referenceURL)
        let shiftedImage = CIImage(cgImage: patternImage).transformed(by: CGAffineTransform(translationX: 4, y: 2)).composited(over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 128))).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 128))
        guard let shiftedCG = context.createCGImage(shiftedImage, from: shiftedImage.extent) else { throw Failure(text: "alignment fixture") }
        try encoded(shiftedCG).write(to: shiftedURL)
        let aligned = try StackProcessor.combine(urls: [referenceURL, shiftedURL], mode: .average, align: true)
        try check(aligned.image.extent.width < 128 && aligned.image.extent.width >= 120 && aligned.image.extent.height >= 120, "translation alignment crops common overlap")
        let alignedPixels = try values(aligned.image)
        let expectedImage = CIImage(cgImage: patternImage).cropped(to: CGRect(x: 0, y: 0, width: aligned.image.extent.width, height: aligned.image.extent.height))
        let expectedPixels = try values(expectedImage)
        let difference = zip(alignedPixels, expectedPixels).enumerated().filter { $0.offset % 4 != 3 }.map { abs(Int($0.element.0) - Int($0.element.1)) }.reduce(0, +)
        try check(Double(difference) / Double(alignedPixels.count * 3 / 4) < 5, "translation alignment restores matching pixels")
        try StackProcessor.validatePixelCount(width: 7452, height: 4973)
        try check(true, "支持实际相机的 3700 万像素尺寸，不会缩图")
        try StackProcessor.validatePixelCount(width: 10_000, height: 10_000)
        try check(true, "接受 1 亿像素上限")
        rejected = false
        do { try StackProcessor.validatePixelCount(width: 10_001, height: 10_000) } catch StackProcessor.Failure.pixelLimit { rejected = true }
        try check(rejected, "超过 1 亿像素明确拒绝")
        try check(StackProcessor.maximumScratchBytes == 16 * 1024 * 1024 * 1024, "临时磁盘上限为 16 GiB")
        let rawURL = ProcessInfo.processInfo.environment["LUMALAB_DNG_FIXTURE"].map {URL(fileURLWithPath:$0)}
        var rawReport = "本机 DNG fixture 不存在，RAW check 跳过"
        if let rawURL,FileManager.default.fileExists(atPath: rawURL.path) {
            let raw = try PhotoIO.decode(data: Data(contentsOf: rawURL, options: .mappedIfSafe), fileExtension: "dng")
            try check(raw.metadata.decoderDescription.contains("LibRaw") || raw.metadata.decoderDescription.contains("RAW Fallback"), "real DNG uses native RAW decoder")
            try check(raw.image.extent.width * raw.image.extent.height > 1_000_000, "real DNG full sensor dimensions")
            let small = raw.image.transformed(by: CGAffineTransform(scaleX: 32 / raw.image.extent.width, y: 32 / raw.image.extent.width))
            let rawPixels = try values(small)
            try check(rawPixels.contains { $0 > 0 && $0 < 255 }, "real DNG actually renders")
            rawReport = "本机 DNG 完整分辨率解码与成像已验证（未复制 Adobe fixture）"
        }
        return "通过 — \(assertions) 项图像解码与堆栈检查；\(rawReport)。"
    }

    private static func makeBMP(width: Int, height: Int) -> Data {
        let stride = (width * 3 + 3) & ~3
        var bytes = [UInt8](repeating: 0, count: 54 + stride * height)
        func put(_ offset: Int, _ value: UInt32, _ count: Int = 4) { for i in 0..<count { bytes[offset + i] = UInt8((value >> (i * 8)) & 255) } }
        bytes[0] = 0x42; bytes[1] = 0x4D
        put(2, UInt32(bytes.count)); put(10, 54); put(14, 40)
        put(18, UInt32(width)); put(22, UInt32(height)); put(26, 1, 2); put(28, 24, 2)
        for y in 0..<height {
            for x in 0..<width {
                let i = 54 + y * stride + x * 3
                // BMP positive height stores bottom row first.
                bytes[i] = 20; bytes[i + 1] = y == height - 1 ? 20 : 80; bytes[i + 2] = y == height - 1 ? 220 : 40
            }
        }
        return Data(bytes)
    }
}
