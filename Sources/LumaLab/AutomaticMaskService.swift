import Foundation
import CoreGraphics
import CoreVideo
import Vision
import CAutomaticMask
import LumaDomain

/// The app depends on this operation, not Vision request classes or ONNX handles.
/// Inference always runs locally. Results are portable coverage, saved with edits.
protocol AutomaticMaskGenerating {
    func generate(_ kind: AutomaticMaskKind, image: CGImage) throws -> [AutomaticMaskResult]
}

enum AutomaticMaskError: LocalizedError {
    case unavailable(String), inference(String), noDetection(String), invalidImage
    var errorDescription: String? {
        switch self {
        case .unavailable(let reason), .inference(let reason), .noDetection(let reason): return reason
        case .invalidImage: return "无法准备自动识别所需的图片。"
        }
    }
}

final class AutomaticMaskService: AutomaticMaskGenerating {
    private let lock = NSLock()
    private var sessions: [String: AutomaticONNXSession] = [:]
    static let shared = AutomaticMaskService()

    func generate(_ kind: AutomaticMaskKind, image: CGImage) throws -> [AutomaticMaskResult] {
        lock.lock(); defer { lock.unlock() }
        switch kind {
        case .subject, .background: return try foreground(kind, image: image)
        case .people: return try people(image)
        case .sky: return try sky(image)
        case .allSkin: return try allSkin(image)
        case .face, .skin, .hair, .eyes, .glasses, .lips: return try faceParts(kind, image: image)
        }
    }

    private func foreground(_ kind: AutomaticMaskKind, image: CGImage) throws -> [AutomaticMaskResult] {
        guard #available(macOS 14.0, *) else {
            throw AutomaticMaskError.unavailable("主题与背景识别需要 macOS 14 或更新版本。人物、面部与天空识别仍可使用。")
        }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw AutomaticMaskError.noDetection("没有识别到清晰的主题。可以改用人物识别或手动画笔。")
        }
        let buffer = try result.generateMask(forInstances: result.allInstances)
        var mask = try raster(buffer, modelID: "apple-vision-foreground-r\(request.revision)")
        if kind == .background {
            mask = try PortableMaskRaster(width: mask.width, height: mask.height, pixels: Data(mask.pixels.map { 255-$0 }), modelID: mask.modelID + "-inverse")
        }
        return [.init(name: kind.title, raster: mask, backend: "Apple Vision adapter")]
    }
    private func people(_ image: CGImage) throws -> [AutomaticMaskResult] {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate; request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        guard let observation = request.results?.first else { throw AutomaticMaskError.noDetection("没有识别到人物。") }
        let mask = try raster(observation.pixelBuffer, modelID: "apple-vision-person-r\(request.revision)")
        guard mask.pixels.contains(where: { $0 > 128 }) else { throw AutomaticMaskError.noDetection("没有识别到人物。") }
        return [.init(name: AutomaticMaskKind.people.title, raster: mask, backend: "Apple Vision adapter")]
    }
    private func sky(_ image: CGImage) throws -> [AutomaticMaskResult] {
        let session = try model("skyseg-fp16")
        let output = try session.predict(image)
        guard output.channels == 1 else { throw AutomaticMaskError.inference("天空识别模型的输出格式不正确。") }
        // U²-Net emits a sigmoid matte. Preserve absolute confidence instead of
        // per-photo min/max normalization, which would invent sky in no-sky photos.
        let pixels = output.values.map { Self.byte($0) }
        guard pixels.filter({ $0 > 160 }).count > max(16,pixels.count/1000) else { throw AutomaticMaskError.noDetection("没有识别到天空，或天空区域过小。") }
        let mask = try PortableMaskRaster(width: output.width, height: output.height, pixels: Data(pixels), modelID: "skyseg-u2net-fp16-74d87f4a-v1")
        return [.init(name: AutomaticMaskKind.sky.title, raster: mask, backend: "ONNX Runtime CPU")]
    }
    private func faceParts(_ kind: AutomaticMaskKind, image: CGImage) throws -> [AutomaticMaskResult] {
        // Detection only locates individual faces. The mask itself comes from a
        // 19-class semantic parsing network, never a face box or skin-color test.
        let request = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        let faces = (request.results ?? []).filter { $0.confidence >= 0.5 }.sorted { $0.boundingBox.midX < $1.boundingBox.midX }
        guard !faces.isEmpty else { throw AutomaticMaskError.noDetection("没有识别到面部。请使用更清晰、面部较大的照片。") }
        let session = try model("face-parsing-resnet18")
        let selected = PortableSegmentation.faceLabels(for: kind)
        let imageBounds = CGRect(x: 0,y: 0,width: image.width,height: image.height)
        let outputScale = min(1,1536.0/Double(max(image.width,image.height)))
        let width = max(1,Int((Double(image.width)*outputScale).rounded()))
        let height = max(1,Int((Double(image.height)*outputScale).rounded()))
        var results: [AutomaticMaskResult] = []
        // Bound memory/time when processing a crowd; individuals remain separate.
        for (index, face) in faces.prefix(20).enumerated() {
            let box = face.boundingBox
            let fw = box.width*Double(image.width), fh = box.height*Double(image.height)
            let centerX = box.midX*Double(image.width)
            let centerY = (1-box.midY)*Double(image.height)
            let side = max(fw*1.8,fh*1.8)
            let crop = CGRect(x: centerX-side/2,y: centerY-side*0.54,width: side,height: side).integral.intersection(imageBounds)
            guard crop.width >= 16, crop.height >= 16, let faceImage = image.cropping(to: crop) else { continue }
            let parsed = try session.predict(faceImage)
            guard parsed.channels == 19 else { throw AutomaticMaskError.inference("面部分割模型的输出格式不正确。") }
            let polygons=Self.eyePolygons(face,image:image,crop:crop)
            let coverage:Data
            if kind == .eyes {
                coverage=try PortableSegmentation.eyeCoverage(logits:parsed.values,width:parsed.width,height:parsed.height,polygons:polygons)
            } else if kind == .skin {
                coverage=try PortableSegmentation.skinCoverage(logits:parsed.values,width:parsed.width,height:parsed.height,rgba:parsed.inputRGBA,eyePolygons:polygons)
            } else {
                coverage=try PortableSegmentation.categoricalCoverage(logits:parsed.values,width:parsed.width,height:parsed.height,channels:parsed.channels,selected:selected)
            }
            guard coverage.contains(where: { $0 > 128 }) else { continue }
            let pixels = try PortableSegmentation.place(coverage, inputWidth: parsed.width, inputHeight: parsed.height,
                x: crop.minX / Double(image.width), y: crop.minY / Double(image.height),
                cropWidth: crop.width / Double(image.width), cropHeight: crop.height / Double(image.height), width: width, height: height)
            let mask = try PortableMaskRaster(width: width,height: height,pixels: pixels,modelID: "face-parsing-bisenet-resnet18-v3-\(kind.rawValue)")
            let name = faces.count > 1 ? "\(kind.title) \(index+1)" : kind.title
            results.append(.init(name:name,raster:mask,backend:"ONNX Runtime CPU; Vision face detection adapter"))
        }
        guard !results.isEmpty else { throw AutomaticMaskError.noDetection("检测到了面部，但没有可靠识别到所选区域。") }
        return results
    }
    private static func polygons(_ regions:[VNFaceLandmarkRegion2D?],face:VNFaceObservation,image:CGImage,crop:CGRect,expandX:Double=1,expandY:Double=1)->[[UnitPoint2D]] {
        let box=face.boundingBox
        return regions.compactMap {$0}.filter {$0.pointCount>=3}.map {region in
            let points=region.normalizedPoints,cx=points.map{Double($0.x)}.reduce(0,+)/Double(points.count),cy=points.map{Double($0.y)}.reduce(0,+)/Double(points.count)
            return points.map {p in
                let x=(box.minX+(cx+(Double(p.x)-cx)*expandX)*box.width)*Double(image.width)
                let y=(1-box.minY-(cy+(Double(p.y)-cy)*expandY)*box.height)*Double(image.height)
                return UnitPoint2D(x:(x-crop.minX)/crop.width,y:(y-crop.minY)/crop.height)
            }
        }
    }
    private static func eyePolygons(_ face:VNFaceObservation,image:CGImage,crop:CGRect)->[[UnitPoint2D]] {
        polygons([face.landmarks?.leftEye,face.landmarks?.rightEye],face:face,image:image,crop:crop,expandX:1.04,expandY:1.08)
    }
    private func allSkin(_ image:CGImage) throws -> [AutomaticMaskResult] {
        let session=try model("selfie-skin"),bounds=CGRect(x:0,y:0,width:image.width,height:image.height)
        let faceRequest=VNDetectFaceLandmarksRequest(),peopleRequest=VNDetectHumanRectanglesRequest()
        peopleRequest.upperBodyOnly=false
        try VNImageRequestHandler(cgImage:image,orientation:.up).perform([faceRequest,peopleRequest])
        let faces=(faceRequest.results ?? []).filter {$0.confidence>=0.5}
        let scale=min(1,1536.0/Double(max(image.width,image.height)))
        let width=max(1,Int(Double(image.width)*scale)),height=max(1,Int(Double(image.height)*scale))
        var pixels=[UInt8](repeating:0,count:width*height),crops=[bounds]
        for person in (peopleRequest.results ?? []).prefix(12) where person.confidence>=0.5 {
            let b=person.boundingBox
            let rect=CGRect(x:b.minX*Double(image.width),y:(1-b.maxY)*Double(image.height),width:b.width*Double(image.width),height:b.height*Double(image.height))
            let crop=rect.insetBy(dx:-rect.width*0.08,dy:-rect.height*0.04).integral.intersection(bounds)
            if crop.width>=32,crop.height>=32,crop.width*crop.height<bounds.width*bounds.height*0.9 {crops.append(crop)}
        }
        for crop in crops {
            guard let part=image.cropping(to:crop) else {continue}
            let output=try session.predict(part)
            guard output.channels==6 else {throw AutomaticMaskError.inference("皮肤模型的输出格式不正确。")}
            let eyes=faces.flatMap {Self.eyePolygons($0,image:image,crop:crop)}
            let excluded=faces.flatMap {Self.polygons([$0.landmarks?.outerLips,$0.landmarks?.leftEyebrow,$0.landmarks?.rightEyebrow],face:$0,image:image,crop:crop)}
            let regions=faces.map {face -> [UnitPoint2D] in
                let b=face.boundingBox,x=(b.minX*Double(image.width)-crop.minX)/crop.width,y=((1-b.maxY)*Double(image.height)-crop.minY)/crop.height
                let w=b.width*Double(image.width)/crop.width,h=b.height*Double(image.height)/crop.height
                return [.init(x:x,y:y),.init(x:x+w,y:y),.init(x:x+w,y:y+h),.init(x:x,y:y+h)]
            }
            let local=try PortableSegmentation.skinCoverage(logits:output.values,width:output.width,height:output.height,channels:6,rgba:output.inputRGBA,eyePolygons:eyes,excludedPolygons:excluded,faceRegions:regions)
            let placed=try PortableSegmentation.place(local,inputWidth:output.width,inputHeight:output.height,x:crop.minX/bounds.width,y:crop.minY/bounds.height,cropWidth:crop.width/bounds.width,cropHeight:crop.height/bounds.height,width:width,height:height)
            for i in pixels.indices {pixels[i]=max(pixels[i],placed[i])}
        }
        // The coarse model finds body skin; the optional fine parser refines
        // faces (including transparent lenses) without becoming a requirement.
        if AutomaticONNXSession.modelURL(name:"face-parsing-resnet18") != nil,
           let detailed=try? faceParts(.skin,image:image) {
            for face in faces {
                let b=face.boundingBox
                let x0=max(0,Int(b.minX*Double(width))),x1=min(width,Int(b.maxX*Double(width)))
                let y0=max(0,Int((1-b.maxY)*Double(height))),y1=min(height,Int((1-b.minY)*Double(height)))
                if x0<x1,y0<y1 {for y in y0..<y1 {for x in x0..<x1 {pixels[y*width+x]=0}}}
            }
            for detail in detailed {
                let placed=try PortableSegmentation.place(detail.raster.pixels,inputWidth:detail.raster.width,inputHeight:detail.raster.height,x:0,y:0,cropWidth:1,cropHeight:1,width:width,height:height)
                for i in pixels.indices {pixels[i]=max(pixels[i],placed[i])}
            }
        }
        guard pixels.contains(where:{$0>128}) else {throw AutomaticMaskError.noDetection("没有识别到清晰的裸露皮肤。")}
        return [.init(name:AutomaticMaskKind.allSkin.title,raster:try PortableMaskRaster(width:width,height:height,pixels:Data(pixels),modelID:"mediapipe-selfie-multiclass-35ec1ecd-skin-v1"),backend:"ONNX Runtime CPU; semantic body/face skin, optional fine face parsing")]
    }
    private func model(_ name: String) throws -> AutomaticONNXSession {
        if let session = sessions[name] { return session }
        let session = try AutomaticONNXSession(name: name)
        sessions[name] = session
        return session
    }
    private func raster(_ buffer: CVPixelBuffer, modelID: String) throws -> PortableMaskRaster {
        CVPixelBufferLockBaseAddress(buffer,.readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer,.readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw AutomaticMaskError.invalidImage }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
        guard width <= 4096 && height <= 4096 else { throw AutomaticMaskError.invalidImage }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        var pixels = [UInt8](repeating:0,count:width*height)
        for y in 0..<height {
            if format == kCVPixelFormatType_OneComponent8 {
                let source = base.advanced(by:y*row).assumingMemoryBound(to:UInt8.self)
                for x in 0..<width { pixels[y*width+x] = source[x] }
            } else if format == kCVPixelFormatType_OneComponent32Float {
                let source = base.advanced(by:y*row).assumingMemoryBound(to:Float.self)
                for x in 0..<width { pixels[y*width+x] = Self.byte(source[x]) }
            } else { throw AutomaticMaskError.invalidImage }
        }
        return try PortableMaskRaster(width:width,height:height,pixels:Data(pixels),modelID:modelID)
    }
    private static func byte(_ value: Float) -> UInt8 { value.isFinite ? UInt8((min(1,max(0,value))*255).rounded()) : 0 }

}

final class AutomaticONNXSession {
    struct Prediction { let width:Int; let height:Int; let channels:Int; let values:[Float]; let inputRGBA:Data }
    private let handle: UnsafeMutableRawPointer
    private let width: Int
    private let height: Int
    private let nhwc:Bool
    static func modelURL(name:String)->URL? {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return [Bundle.main.resourceURL?.appendingPathComponent("AutoMasks/"+name+".onnx"),root.appendingPathComponent("Resources/AutoMasks/"+name+".onnx")].compactMap{$0}.first {FileManager.default.fileExists(atPath:$0.path)}
    }
    init(name: String) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let model=Self.modelURL(name:name) else {throw AutomaticMaskError.unavailable(name=="face-parsing-resnet18" ? "面部细分模型为可选组件，未包含在此构建中。请查看 MODEL_LICENSES.md 的获取方式与使用限制。":"自动识别模型缺失，请运行 scripts/fetch-dependencies.py 后重新构建。")}
        let runtimes = [Bundle.main.privateFrameworksURL?.appendingPathComponent("libonnxruntime.1.20.1.dylib"),root.appendingPathComponent("Vendor/ONNXRuntime/lib/libonnxruntime.1.20.1.dylib")].compactMap{$0}
        guard let runtime = runtimes.first(where:{FileManager.default.fileExists(atPath:$0.path)}) else { throw AutomaticMaskError.unavailable("此安装包缺少本地模型运行库。") }
        var error = [CChar](repeating:0,count:4096)
        guard let handle = luma_onnx_create(runtime.path,model.path,&error,error.count) else { throw AutomaticMaskError.inference(String(cString:error)) }
        var shape = [Int64](repeating:0,count:4)
        let nhwc=name=="selfie-skin"
        guard luma_onnx_input_shape(handle,&shape,&error,error.count) != 0,(shape[0]==1 || shape[0]==(-1)),
              (nhwc ? shape[3]:shape[1])==3,
              (nhwc ? shape[1]:shape[2])>0,(nhwc ? shape[2]:shape[3])>0,
              (nhwc ? shape[1]:shape[2])<=2048,(nhwc ? shape[2]:shape[3])<=2048 else {
            luma_onnx_destroy(handle);throw AutomaticMaskError.inference("自动识别模型的输入格式不受支持。")
        }
        self.handle=handle;self.nhwc=nhwc;self.width=Int(nhwc ? shape[2]:shape[3]);self.height=Int(nhwc ? shape[1]:shape[2])
    }
    deinit { luma_onnx_destroy(handle) }
    func predict(_ image: CGImage) throws -> Prediction {
        var rgba = [UInt8](repeating:0,count:width*height*4)
        let colorSpace = CGColorSpace(name:CGColorSpace.sRGB)!
        let success = rgba.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data:storage.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:colorSpace,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.interpolationQuality = .high
            // CGContext raw rows and CGImage both use their native top-to-bottom
            // storage; draw without a UI-coordinate flip, preserving pixel order.
            context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
            return true
        }
        guard success else { throw AutomaticMaskError.invalidImage }
        var tensor = try nhwc ? PortableSegmentation.unitNHWCTensor(Data(rgba),width:width,height:height) : PortableSegmentation.normalizedRGBATensor(Data(rgba), width: width, height: height)
        var shape:[Int64] = nhwc ? [1,Int64(height),Int64(width),3]:[1,3,Int64(height),Int64(width)]
        var output:UnsafeMutablePointer<Float>?, outputShape = [Int64](repeating:0,count:4), count = 0
        var error = [CChar](repeating:0,count:4096)
        guard luma_onnx_run(handle,&tensor,&shape,&output,&outputShape,&count,&error,error.count) != 0, let output else { throw AutomaticMaskError.inference(String(cString:error)) }
        defer { luma_onnx_free(output) }
        guard outputShape[0] == 1, outputShape[1] > 0, outputShape[2] > 0, outputShape[3] > 0,
              count == Int(outputShape[1]*outputShape[2]*outputShape[3]) else { throw AutomaticMaskError.inference("自动识别输出尺寸无效。") }
        let ow=Int(nhwc ? outputShape[2]:outputShape[3]),oh=Int(nhwc ? outputShape[1]:outputShape[2]),channels=Int(nhwc ? outputShape[3]:outputShape[1])
        var values=Array(UnsafeBufferPointer(start:output,count:count))
        if nhwc {values=try PortableSegmentation.planarNHWCLogits(values,width:ow,height:oh,channels:channels)}
        return Prediction(width:ow,height:oh,channels:channels,values:values,inputRGBA:Data(rgba))
    }
}
