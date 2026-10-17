import LumaDomain
import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

struct DecodedPhoto {
    let image: CIImage
    let metadata: PhotoMetadata
    var decoderDescription: String { metadata.decoderDescription }
}

struct PhotoMetadata {
    var properties: [String: Any] = [:]
    var rows: [(String, String)] = []
    /// EV100 derived from shutter, aperture and ISO; optional when EXIF is absent.
    var exposureEV: Double?
    var decoderDescription = "系统完整分辨率解码"
}

enum PhotoIO {
    enum Failure: LocalizedError {
        case unreadable, unsupportedRAW, invalidDimensions, rawPreviewOnly
        var errorDescription: String? {
            switch self {
            case .unreadable: return "无法读取这张图像，或文件已损坏。支持 JPEG、PNG、BMP、TIFF、DNG，以及 macOS 支持的相机 RAW。"
            case .unsupportedRAW: return "当前 macOS 的 RAW 解码器不支持这台相机或这个文件。不会改用内嵌预览图；请先转换为兼容的 DNG 或 TIFF。"
            case .invalidDimensions: return "图像尺寸无效，无法解码。"
            case .rawPreviewOnly: return "RAW 解码器未返回完整分辨率图像；为避免误用预览图，已停止打开。"
            }
        }
    }
    static let rawExtensions: Set<String> = ["dng", "raw", "crw", "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef", "srw", "x3f", "3fr", "fff", "iiq", "rwl", "erf", "mrw", "mos", "mef", "dcr", "kdc"]
    static var supportedExtensions: [String] { ["jpg", "jpeg", "png", "bmp", "tif", "tiff"] + rawExtensions.sorted() }
    static var supportedContentTypes: [UTType] {
        var types: [UTType] = [.jpeg, .png, .bmp, .tiff, .rawImage]
        for ext in supportedExtensions {
            if let type = UTType(filenameExtension: ext), !types.contains(type) { types.append(type) }
        }
        return types
    }
    static func supports(_ url: URL) -> Bool { supportedExtensions.contains(url.pathExtension.lowercased()) }

    static func decode(data: Data, fileExtension: String? = nil) throws -> DecodedPhoto {
        guard !data.isEmpty else { throw Failure.unreadable }
        let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        let identifier = source.flatMap { CGImageSourceGetType($0) }.map { $0 as String }
        let type = identifier.flatMap { UTType($0) }
        var properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [String: Any] ?? [:]
        let dngCandidate = fileExtension?.lowercased()=="dng" || identifier=="public.tiff" || properties[kCGImagePropertyDNGDictionary as String] != nil
        let dng = dngCandidate && DNGMetadataStore.isDNG(data:data)
        let raw = dng || rawExtensions.contains(fileExtension?.lowercased() ?? "") || type?.conforms(to: .rawImage) == true || properties[kCGImagePropertyDNGDictionary as String] != nil
        let image: CIImage
        let description: String
        if raw {
            if let type = type, !type.conforms(to: .rawImage), [.jpeg, .png, .bmp, .tiff].contains(type), properties[kCGImagePropertyDNGDictionary as String] == nil && !dng {
                throw Failure.unsupportedRAW
            }
            if let decoded = try? SharedRAWDecoder.decode(data) {
                var raster=Data(count:decoded.width*decoded.height*8)
                raster.withUnsafeMutableBytes {destination in decoded.rgb16.withUnsafeBytes {source in
                    let rgba=destination.bindMemory(to:UInt16.self),samples=source.bindMemory(to:UInt16.self)
                    for i in 0..<decoded.width*decoded.height {rgba[i*4]=samples[i*3];rgba[i*4+1]=samples[i*3+1];rgba[i*4+2]=samples[i*3+2];rgba[i*4+3]=65535}
                }}
                let linear=CGColorSpace(name:CGColorSpace.linearSRGB)!
                let full=CIImage(bitmapData:raster,bytesPerRow:decoded.width*8,size:CGSize(width:decoded.width,height:decoded.height),format:.RGBA16,colorSpace:linear)
                var metadata=extractMetadata(properties:properties,size:full.extent.size)
                metadata.decoderDescription="LibRaw \(SharedRAWDecoder.version) · 完整分辨率 Linear sRGB16"
                metadata.rows.append(("解码方式",metadata.decoderDescription))
                if metadata.exposureEV == nil,decoded.iso>0,decoded.shutter>0,decoded.aperture>0 {metadata.exposureEV=log2(decoded.aperture*decoded.aperture/decoded.shutter*100/decoded.iso)}
                if !decoded.make.isEmpty {metadata.rows.append(("RAW 相机",decoded.make+" "+decoded.model))}
                return DecodedPhoto(image:full,metadata:metadata)
            }
            // Explicit platform fallback for RAW variants unsupported by this LibRaw build.
            guard let filter = CIRAWFilter(imageData: data, identifierHint: dng ? "com.adobe.raw-image" : identifier) else { throw Failure.unsupportedRAW }
            filter.scaleFactor = 1
            filter.isDraftModeEnabled = false
            guard let full = filter.outputImage else { throw Failure.unsupportedRAW }
            let native = filter.nativeSize
            if native.width > 0 && native.height > 0 && full.extent.width * full.extent.height < native.width * native.height * 0.5 {
                throw Failure.rawPreviewOnly
            }
            image = full
            // CIRAWFilter handles EXIF orientation itself, including native RAW data.
            for (key, value) in filter.properties { if let key = key as? String { properties[key] = value } }
            description = "macOS RAW Fallback（LibRaw 未支持此文件；完整分辨率，非预览图）"
        } else {
            guard let source = source,
                  let bitmap = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw Failure.unreadable }
            let orientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.int32Value ?? 1
            image = CIImage(cgImage: bitmap).oriented(forExifOrientation: orientation)
            description = "系统完整分辨率解码（已应用拍摄方向）"
        }
        guard image.extent.width.isFinite, image.extent.height.isFinite,
              image.extent.width >= 1, image.extent.height >= 1,
              image.extent.width <= 100_000, image.extent.height <= 100_000 else { throw Failure.invalidDimensions }
        let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        var metadata = extractMetadata(properties: properties, size: normalized.extent.size)
        metadata.decoderDescription = description
        metadata.rows.append(("解码方式", description))
        return DecodedPhoto(image: normalized, metadata: metadata)
    }

    static func extractMetadata(properties: [String: Any], size: CGSize) -> PhotoMetadata {
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        func string(_ value: Any?) -> String? {
            guard let value = value else { return nil }
            if let array = value as? [NSNumber] { return array.map { $0.stringValue }.joined(separator: ", ") }
            let result = String(describing: value)
            return result.isEmpty ? nil : result
        }
        func number(_ value: Any?) -> Double? {
            if let value = value as? NSNumber { return value.doubleValue }
            if let value = value as? String { return Double(value) }
            return nil
        }
        var rows: [(String, String)] = [("图像尺寸", "\(Int(size.width)) × \(Int(size.height)) 像素")]
        func add(_ title: String, _ value: Any?) { if let text = string(value) { rows.append((title, text)) } }
        add("相机品牌", tiff[kCGImagePropertyTIFFMake as String])
        add("相机型号", tiff[kCGImagePropertyTIFFModel as String])
        add("镜头", exif[kCGImagePropertyExifLensModel as String])
        let isoValue = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue
            ?? number(exif[kCGImagePropertyExifISOSpeedRatings as String])
        if let iso = isoValue { rows.append(("感光度", String(format: "%.0f", iso))) }
        let time = number(exif[kCGImagePropertyExifExposureTime as String])
        if let time = time, time > 0 { rows.append(("快门", time < 1 ? String(format: "1/%.0f 秒", 1 / time) : String(format: "%.3g 秒", time))) }
        let aperture = number(exif[kCGImagePropertyExifFNumber as String])
        if let aperture = aperture { rows.append(("光圈", String(format: "f/%.1f", aperture))) }
        if let focal = number(exif[kCGImagePropertyExifFocalLength as String]) { rows.append(("焦距", String(format: "%.1f 毫米", focal))) }
        add("拍摄时间", exif[kCGImagePropertyExifDateTimeOriginal as String] ?? tiff[kCGImagePropertyTIFFDateTime as String])
        add("位深", properties[kCGImagePropertyDepth as String])
        add("色彩配置", properties[kCGImagePropertyProfileName as String])
        var ev: Double?
        if let t = time, let n = aperture, let iso = isoValue, t > 0, n > 0, iso > 0 {
            let candidate = log2(n * n / t * 100 / iso)
            if candidate.isFinite { ev = candidate }
        }
        return PhotoMetadata(properties: properties, rows: rows, exposureEV: ev)
    }
}
