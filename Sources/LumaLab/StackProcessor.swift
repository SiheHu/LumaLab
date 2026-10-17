import LumaDomain
import Foundation
import CoreImage
import Vision

struct StackResult {
    let image: CIImage
    let report: String
}

enum StackProcessor {
    enum Failure: LocalizedError {
        case count(Int), fileLimit, pixelLimit, diskLimit, dimensions, alignment(String), rendering, cancelled
        var errorDescription: String? {
            switch self {
            case .count(let limit): return "请选择 2–\(limit) 张原始图像。"
            case .fileLimit: return "这组原始文件超过 256 MiB；为限制内存占用，请减少张数或选择较小的文件。不会自动降低分辨率。"
            case .diskLimit: return "堆栈需要的临时磁盘空间不足，或超过 16 GiB 临时文件限制；请减少图像张数。临时文件会在操作后删除。"
            case .pixelLimit: return "单张堆栈图像最多 1 亿像素。请先导出所需尺寸的 TIFF；不会自动降低分辨率。"
            case .dimensions: return "所有原始图像应用拍摄方向后必须具有相同尺寸；请先统一尺寸。"
            case .alignment(let reason): return "平移对齐失败：\(reason)。请使用三脚架拍摄的图像，或关闭对齐后重试。"
            case .rendering: return "堆栈图像生成失败；需要允许访问本机图形服务。"
            case .cancelled: return "已取消堆栈。"
            }
        }
    }
    static let maximumPixelsPerFrame = 100_000_000
    static let maximumScratchBytes: Int64 = 16 * 1024 * 1024 * 1024
    static func validatePixelCount(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= maximumPixelsPerFrame / height else { throw Failure.pixelLimit }
    }
    private static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    static func combine(urls: [URL], mode: StackMode, align: Bool, rotation:Bool=false, deghost:Double=0, sigma:Float=3,
                        progress: @escaping (Double) -> Void = { _ in }) throws -> StackResult {
        if mode == .panorama {return try PanoramaProcessor.combine(urls:urls,progress:progress)}
        let limit = mode == .median ? 15 : 32
        guard urls.count >= 2 && urls.count <= limit else { throw Failure.count(limit) }
        var fileBytes: Int64 = 0
        for url in urls {
            fileBytes += Int64((try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
            guard fileBytes <= 256 * 1024 * 1024 else { throw Failure.fileLimit }
        }
        let context = CIContext(options: [.workingColorSpace: linear, .outputColorSpace: linear, .cacheIntermediates: false])
        var transforms: [CGAffineTransform] = []
        var exposures: [Double?] = []
        var originalBounds = CGRect.zero
        var commonBounds = CGRect.zero
        var reference: CGImage?
        var referenceScale: CGFloat = 1
        var referenceImage:CIImage?
        var rotationUsed=false
        for (index, url) in urls.enumerated() {
            if Thread.current.isCancelled { throw Failure.cancelled }
            let decoded = try PhotoIO.decode(data: Data(contentsOf: url, options: .mappedIfSafe), fileExtension: url.pathExtension)
            var image = decoded.image
            var frameTransform = CGAffineTransform.identity
            let bounds = image.extent.integral
            try validatePixelCount(width: Int(bounds.width), height: Int(bounds.height))
            if index == 0 {
                originalBounds = bounds; commonBounds = bounds
                if rotation {referenceImage=image}
                if align {
                    referenceScale = min(1, 1024 / max(bounds.width, bounds.height))
                    let small = image.transformed(by: CGAffineTransform(scaleX: referenceScale, y: referenceScale))
                    reference = context.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: srgb)
                    guard reference != nil else { throw Failure.rendering }
                }
            } else {
                guard bounds.size == originalBounds.size else { throw Failure.dimensions }
                if align, let reference = reference {
                    let transform:CGAffineTransform
                    if rotation,let referenceImage,let registered=try? ImageRegistration.align(image,to:referenceImage,context:context) {
                        transform=ImageRegistration.affine(registered,movingHeight:bounds.height,referenceHeight:originalBounds.height)
                        rotationUsed = rotationUsed || abs(transform.b)>0.00001
                    } else {transform = try translation(image:image,reference:reference,scale:referenceScale)}
                    guard abs(transform.tx) < bounds.width * 0.15 && abs(transform.ty) < bounds.height * 0.15 else {
                        throw Failure.alignment("位移超过图像尺寸的 15%；不支持大范围相机移动")
                    }
                    frameTransform = transform
                    image = image.transformed(by: transform)
                    commonBounds = commonBounds.intersection(image.extent)
                }
            }
            transforms.append(frameTransform)
            exposures.append(decoded.metadata.exposureEV)
            progress(0.1 * Double(index + 1) / Double(urls.count))
        }
        if rotationUsed {
            var coverage=CIImage(color:.white).cropped(to:commonBounds)
            for transform in transforms {
                let frame=CIImage(color:.white).cropped(to:originalBounds).transformed(by:transform)
                coverage=coverage.applyingFilter("CISourceInCompositing",parameters:[kCIInputBackgroundImageKey:frame]).cropped(to:commonBounds)
            }
            let normalized=coverage.transformed(by:CGAffineTransform(translationX:-commonBounds.minX,y:-commonBounds.minY))
            let crop=try GeometryAutoCrop.region(in:normalized,context:context)
            commonBounds=CGRect(x:commonBounds.minX+crop.x*commonBounds.width,y:commonBounds.minY+(1-crop.y-crop.height)*commonBounds.height,width:crop.width*commonBounds.width,height:crop.height*commonBounds.height)
        }
        let left = ceil(commonBounds.minX), bottom = ceil(commonBounds.minY)
        let right = floor(commonBounds.maxX), top = floor(commonBounds.maxY)
        let outputBounds = CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
        guard outputBounds.width >= 1, outputBounds.height >= 1 else { throw Failure.alignment("没有共同覆盖的图像区域") }
        let width = Int(outputBounds.width), height = Int(outputBounds.height)
        let byteCount = width * height * 4 * MemoryLayout<Float>.size
        let diskBytes = Int64(byteCount) * Int64(urls.count)
        let scratchRoot = FileManager.default.temporaryDirectory.appendingPathComponent("LumaLab-stack-\(UUID().uuidString)", isDirectory: true)
        let free = (try? FileManager.default.attributesOfFileSystem(forPath: scratchRoot.deletingLastPathComponent().path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard diskBytes <= maximumScratchBytes, free > diskBytes + 512 * 1024 * 1024 else { throw Failure.diskLimit }
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchRoot) }
        var cached: [URL] = []
        // Decode one complete frame at a time. A disk-backed linear raster avoids
        // retaining N full-resolution decoder graphs or N Float images in RAM.
        for (index, url) in urls.enumerated() {
            if Thread.current.isCancelled { throw Failure.cancelled }
            let destination = scratchRoot.appendingPathComponent("frame-\(index).rgba32f")
            try autoreleasepool {
                let decoded = try PhotoIO.decode(data: Data(contentsOf: url, options: .mappedIfSafe), fileExtension: url.pathExtension)
                let image = decoded.image.transformed(by: transforms[index])
                guard let raster = context.createCGImage(image, from: outputBounds, format: .RGBAf, colorSpace: linear),
                      let data = raster.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { throw Failure.rendering }
                guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw Failure.diskLimit }
                let handle = try FileHandle(forWritingTo: destination)
                defer { try? handle.close() }
                if raster.bytesPerRow == width * 16 { try handle.write(contentsOf: data as Data) }
                else {
                    for y in 0..<height { try handle.write(contentsOf: Data(bytes: bytes.advanced(by: y * raster.bytesPerRow), count: width * 16)) }
                }
            }
            context.clearCaches()
            cached.append(destination)
            progress(0.1 + 0.35 * Double(index + 1) / Double(urls.count))
        }
        var handles: [FileHandle] = []
        defer { for handle in handles { try? handle.close() } }
        for url in cached { handles.append(try FileHandle(forReadingFrom: url)) }
        let allocation = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
        var transferred = false
        defer { if !transferred { allocation.deallocate() } }
        let output = allocation.bindMemory(to: Float.self, capacity: width * height * 4)
        output.initialize(repeating: 0, count: width * height * 4)
        // Tile storage remains <= 24 MiB, independent of photo dimensions.
        let tileRows = max(1, min(128, 24 * 1024 * 1024 / max(1, width * urls.count * 4 * 4)))
        let hasExposures = exposures.allSatisfy { $0 != nil }
        let referenceEV = exposures.compactMap { $0 }.sorted().dropFirst(exposures.compactMap { $0 }.count / 2).first ?? 0
        let gains = exposures.map { ev -> Float in
            guard hasExposures, let ev = ev, mode == .hdr else { return 1 }
            return Float(pow(2, min(16, max(-16, ev - referenceEV))))
        }
        let referenceFrame=exposures.indices.min(by:{abs((exposures[$0] ?? 0)-referenceEV)<abs((exposures[$1] ?? 0)-referenceEV)}) ?? 0
        var sampleScratch = [Float](repeating: 0, count: urls.count)
        for row in stride(from: 0, to: height, by: tileRows) {
            if Thread.current.isCancelled { throw Failure.cancelled }
            let rows = min(tileRows, height - row)
            let halo=mode == .focus ? 3:0
            let start=max(0,row-halo),end=min(height,row+rows+halo),readRows=end-start
            var tiles: [[Float]] = []
            for handle in handles {
                try handle.seek(toOffset:UInt64(start*width*16))
                let expected = width * readRows * 16
                guard let data = try handle.read(upToCount: expected), data.count == expected else { throw Failure.rendering }
                var values = [Float](repeating: 0, count: width * readRows * 4)
                _ = values.withUnsafeMutableBytes { destination in data.copyBytes(to: destination) }
                tiles.append(values)
            }
            let scores = mode == .focus ? tiles.map {PortableStack.focusScores($0,width:width,height:readRows)}:[]
            for pixel in 0..<(width * rows) {
                let index=pixel+(row-start)*width
                let local = index * 4, target = (row * width + pixel) * 4
                if mode == .focus {
                    var total:Float=0
                    for frame in scores.indices {total+=scores[frame][index]}
                    total=max(1e-20,total)
                    for c in 0..<3 {
                        var sum:Float=0
                        for frame in tiles.indices {sum+=tiles[frame][local+c]*scores[frame][index]}
                        output[target+c]=sum/total
                    }
                    output[target+3]=1;continue
                }
                if mode == .hdr {
                    var sumWeight: Float = 0
                    var sums: (Float, Float, Float) = (0, 0, 0)
                    let reference=referenceFrame
                    var ghost=false
                    if deghost>0 {
                        let r=tiles[reference][local],g=tiles[reference][local+1],b=tiles[reference][local+2]
                        let refGain=gains[reference],light=max(Float(0.03),(r+g+b)*refGain/3)
                        if max(r,max(g,b))<0.98 {
                            let threshold=max(Float(0.01),Float(0.6-deghost*0.5)*light)
                            for frame in tiles.indices where frame != reference {
                                let v=tiles[frame],gain=gains[frame]
                                if max(v[local],max(v[local+1],v[local+2]))>=0.98 {continue}
                                let delta=max(abs(v[local]*gain-r*refGain),max(abs(v[local+1]*gain-g*refGain),abs(v[local+2]*gain-b*refGain)))
                                if delta>threshold {ghost=true;break}
                            }
                        }
                    }
                    for index in tiles.indices where !ghost || index==reference {
                        let values = tiles[index]
                        let r = clean(values[local]), g = clean(values[local + 1]), b = clean(values[local + 2])
                        let luminance = max(0, 0.2126 * r + 0.7152 * g + 0.0722 * b)
                        let encoded = pow(min(1, luminance), Float(1 / 2.2))
                        let weight = exp(-pow((encoded - 0.5) / 0.22, 2) / 2) + 0.001
                        sumWeight += weight
                        sums.0 += r * gains[index] * weight; sums.1 += g * gains[index] * weight; sums.2 += b * gains[index] * weight
                    }
                    let r = sums.0 / sumWeight, g = sums.1 / sumWeight, b = sums.2 / sumWeight
                    let luminance = max(0.000001, 0.2126 * r + 0.7152 * g + 0.0722 * b)
                    // Global Reinhard compression creates an explicit SDR result.
                    let scale = min(1 / luminance, 1.35 / (1 + luminance))
                    output[target] = min(1, max(0, r * scale)); output[target + 1] = min(1, max(0, g * scale)); output[target + 2] = min(1, max(0, b * scale))
                    output[target + 3] = 1
                } else {
                    for channel in 0..<4 {
                        switch mode {
                        case .average:
                            var sum: Float = 0
                            for frame in tiles { sum += clean(frame[local + channel]) }
                            output[target + channel] = sum / Float(tiles.count)
                        case .starTrails:
                            var value: Float = 0
                            for frame in tiles { value = max(value, clean(frame[local + channel])) }
                            output[target + channel] = value
                        case .median:
                            for index in tiles.indices { sampleScratch[index] = clean(tiles[index][local + channel]) }
                            sampleScratch.sort()
                            let middle = sampleScratch.count / 2
                            output[target + channel] = sampleScratch.count % 2 == 0 ? (sampleScratch[middle - 1] + sampleScratch[middle]) / 2 : sampleScratch[middle]
                        case .sigmaClip:
                            for frame in tiles.indices {sampleScratch[frame]=clean(tiles[frame][local+channel])}
                            output[target+channel]=PortableStack.sigmaClippedMean(sampleScratch,sigma:sigma)
                        case .hdr,.focus,.panorama: break
                        }
                    }
                }
            }
            progress(0.45 + 0.55 * Double(row + rows) / Double(height))
            context.clearCaches()
        }
        let data = Data(bytesNoCopy: allocation, count: byteCount, deallocator: .custom { pointer, _ in pointer.deallocate() })
        transferred = true
        let image = CIImage(bitmapData: data, bytesPerRow: width * 16, size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: linear)
        var notes = ["\(urls.count) 张 · \(width) × \(height) 像素 · 完整分辨率线性光浮点运算"]
        if align { notes.append(rotationUsed ? "Rotation Registration 已完成，裁去共同覆盖区域外的透明边缘。":"Translation Registration 已完成，输出已裁到共同覆盖区域。") }
        else { notes.append("未对齐；请使用固定三脚架。星轨通常应关闭对齐。") }
        if mode == .hdr {
            notes.append(hasExposures ? "HDR：按拍摄参数归一化曝光，对曝光适中的像素加权并进行全局色调映射，输出标准动态范围图像。" : "HDR：缺少完整拍摄参数，回退为不校准曝光的像素加权融合与全局色调映射，输出标准动态范围图像。")
            notes.append(deghost>0 ? "Deghost 已启用，运动区域使用参考帧。":"Deghost 未启用。")
        }
        return StackResult(image: image, report: notes.joined(separator: "\n"))
    }

    private static func clean(_ value: Float) -> Float { value.isFinite ? min(65_504, max(0, value)) : 0 }

    private static func translation(image: CIImage, reference: CGImage, scale: CGFloat) throws -> CGAffineTransform {
        let moving = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let request = VNTranslationalImageRegistrationRequest(targetedCIImage: moving, options: [:])
        do {
            try VNImageRequestHandler(cgImage: reference, options: [:]).perform([request])
            guard let result = request.results?.first else { throw Failure.alignment("没有找到可靠的图像匹配") }
            let transform = result.alignmentTransform
            guard transform.tx.isFinite, transform.ty.isFinite else { throw Failure.alignment("匹配返回无效位移") }
            return CGAffineTransform(translationX: transform.tx / scale, y: transform.ty / scale)
        } catch let error as Failure { throw error }
        catch { throw Failure.alignment(error.localizedDescription) }
    }
}
