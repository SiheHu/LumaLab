import LumaDomain
import Foundation
import CoreImage
import CoreGraphics

extension RepairMode {var title:String {switch self {case .heal: return "修复"; case .clone: return "仿制"; case .inpaint: return "内容移除"}}}

/// Repairs are solved in full-resolution local regions before color/geometry.
/// Prefix caching retains local patches, never a full floating-point copy per stroke.
final class RepairProcessor {
    private let context=CIContext(options:[.workingColorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!, .cacheIntermediates:false])
    private let space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
    private let lock=NSLock()
    private var cachedSource:CIImage?
    private var generatedInpaint: (source: CIImage, key: RepairStroke, image: CIImage)?
    private var cached:[(stroke:RepairStroke,result:CIImage)] = []
    private let patchBlendKernel=CIColorKernel(source:"kernel vec4 copyPatch(__sample front, __sample back, __sample mask) {return mix(back,front,clamp(mask.r,0.0,1.0));}")
    private let healKernel=CIColorKernel(source:"""
        kernel vec4 healPatch(__sample target, __sample source, __sample correction, __sample mask, float opacity) {
            vec4 t=unpremultiply(target), s=unpremultiply(source);
            float weight=clamp(mask.r*opacity,0.0,1.0)*step(0.999,s.a);
            return premultiply(vec4(mix(t.rgb,s.rgb+correction.rgb,weight),t.a));
        }
        """)
    private let inpaintingKernel=CIColorKernel(source:"""
        kernel vec4 contentRepair(__sample target, __sample source, __sample mask, float opacity) {
            vec4 t=unpremultiply(target), s=unpremultiply(source);
            float weight=clamp(mask.r*opacity,0.0,1.0);
            return premultiply(vec4(mix(t.rgb,s.rgb,weight),t.a));
        }
        """)
    private let cloneKernel=CIColorKernel(source:"""
        kernel vec4 clonePatch(__sample target, __sample source, __sample mask, float opacity) {
            vec4 t=unpremultiply(target), s=unpremultiply(source);
            float weight=clamp(mask.r*opacity,0.0,1.0)*step(0.999,s.a);
            return premultiply(vec4(mix(t.rgb,s.rgb,weight),t.a));
        }
        """)
    enum Failure:LocalizedError {
        case invalid, tooLarge, kernel
        var errorDescription:String? {
            switch self {
            case .invalid:return "修复笔触或取样区域无效，请调整取样位置。"
            case .tooLarge:return "这条修复笔触的区域过大，请拆成较短笔触。"
            case .kernel:return "无法生成修复效果。"
            }
        }
    }
    func apply(source:CIImage,strokes:[RepairStroke]) throws -> CIImage {
        lock.lock();defer {lock.unlock()}
        if cachedSource !== source {cachedSource=source;cached=[];generatedInpaint=nil}
        let active=strokes.filter {$0.enabled && $0.opacity>0 && !$0.points.isEmpty}
        var common=0
        while common<min(active.count,cached.count), cached[common].stroke==active[common] {common+=1}
        var image=common>0 ? cached[common-1].result:source
        if common==active.count {return image}
        cached=Array(cached.prefix(common))
        for stroke in active.dropFirst(common) {
            image=try apply(stroke,to:image)
            cached.append((stroke,image))
        }
        return image
    }
    private func apply(_ stroke:RepairStroke,to image:CIImage) throws -> CIImage {
        guard (1...3).contains(stroke.algorithmVersion), stroke.radius.isFinite, stroke.feather.isFinite, stroke.opacity.isFinite,
              stroke.source.x.isFinite,stroke.source.y.isFinite,
              stroke.points.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else {throw Failure.invalid}
        let bounds=image.extent, w=bounds.width,h=bounds.height
        let radius=max(0.5,min(0.45,stroke.radius)*min(w,h))
        let positions=stroke.points.map {CGPoint(x:$0.x*w,y:(1-$0.y)*h)}
        let xs=positions.map(\.x),ys=positions.map(\.y)
        // Content removal must replace every pixel inside the painted core.
        // Its Feather extends outside that core rather than mixing the object
        // back into the filled region. Keep older saved strokes reproducible.
        let featherWidth=PortableHealing.inpaintingFeatherWidth(radius:radius,imageShortDimension:min(w,h),feather:stroke.feather)
        let outerRadius=stroke.mode == .inpaint && stroke.algorithmVersion>=3 ? radius+featherWidth:radius
        let padding=stroke.algorithmVersion>=3 && stroke.mode == .heal ? max(6,radius*0.4):3
        let region=CGRect(x:xs.min()!-outerRadius-padding,y:ys.min()!-outerRadius-padding,width:xs.max()!-xs.min()!+2*(outerRadius+padding),height:ys.max()!-ys.min()!+2*(outerRadius+padding)).integral.intersection(bounds)
        guard !region.isEmpty else {return image}
        guard region.width*region.height<=20_000_000 else {throw Failure.tooLarge}
        if stroke.mode == .inpaint { return try applyInpainting(stroke, to: image, target: region, positions: positions, radius: radius) }
        let dx=(stroke.anchor.x-stroke.source.x)*w,dy=(stroke.source.y-stroke.anchor.y)*h
        let sampled=image.transformed(by:CGAffineTransform(translationX:dx,y:dy))
        let coverage=try mask(points:positions,radius:radius,feather:stroke.feather,region:region,version:stroke.algorithmVersion)
        let patch:CIImage?
        if stroke.mode == .clone {
            patch=cloneKernel?.apply(extent:region,arguments:[image,sampled,coverage,min(1,max(0,stroke.opacity))])
        } else {
            let solveMask=stroke.algorithmVersion>=3 ? try mask(points:positions,radius:radius,feather:0,region:region,version:3):coverage
            let correction=try harmonicCorrection(target:image,source:sampled,mask:solveMask,region:region,radius:radius,version:stroke.algorithmVersion)
            patch=healKernel?.apply(extent:region,arguments:[image,sampled,correction,coverage,min(1,max(0,stroke.opacity))])
        }
        guard let patch=patch else {throw Failure.kernel}
        // Bake only the local patch. Later previews never replay all previous solves.
        guard let baked=context.createCGImage(patch,from:region,format:.RGBAh,colorSpace:space) else {throw Failure.kernel}
        let local=CIImage(cgImage:baked).transformed(by:CGAffineTransform(translationX:region.minX,y:region.minY))
        guard let result=patchBlendKernel?.apply(extent:bounds,arguments:[local.clampedToExtent(),image,CIImage(color:.white).cropped(to:region)]) else {throw Failure.kernel}
        return result
    }
    /// Generate only a contextual local patch; original pixels outside the Brush
    /// stay on the full-resolution graph. The shared ONNX processor receives a
    /// bounded sRGB raster and never sees AppKit/Core Image objects.
    private func applyInpainting(_ stroke: RepairStroke, to image: CIImage, target: CGRect, positions: [CGPoint], radius: CGFloat) throws -> CIImage {
        var key = stroke; if stroke.algorithmVersion<3 {key.feather = 0}; key.opacity = 1; key.enabled = true; key.source = .center
        let featherWidth=stroke.algorithmVersion>=3 ? PortableHealing.inpaintingFeatherWidth(radius:radius,imageShortDimension:min(image.extent.width,image.extent.height),feather:stroke.feather):0
        let outerRadius=radius+featherWidth
        let generated: CIImage
        if let cached = generatedInpaint, cached.source === image, cached.key == key {
            generated = cached.image
        } else {
        let roi = target.insetBy(dx: -max(64, target.width*0.6), dy: -max(64, target.height*0.6)).integral.intersection(image.extent)
        let factor = min(1, 2048/max(roi.width,roi.height))
        let width = max(1,Int((roi.width*factor).rounded())), height = max(1,Int((roi.height*factor).rounded()))
        let sx = CGFloat(width)/roi.width, sy = CGFloat(height)/roi.height
        let input = image.cropped(to: roi).transformed(by: CGAffineTransform(translationX: -roi.minX,y: -roi.minY))
            .clampedToExtent().transformed(by: CGAffineTransform(scaleX: sx,y: sy)).cropped(to: CGRect(x:0,y:0,width:width,height:height))
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        var bytes = Data(repeating: 0, count: width*height*4)
        bytes.withUnsafeMutableBytes {context.render(input,toBitmap:$0.baseAddress!,rowBytes:width*4,bounds:input.extent,format:.RGBA8,colorSpace:sRGB)}
        let path = positions.map { UnitPoint2D(x:($0.x-roi.minX)/roi.width, y:(roi.maxY-$0.y)/roi.height) }
        // Model input is binary coverage. Feather and opacity are applied exactly
        // once by the final compositor, without exposing partial object pixels.
        let modelMask = PortableBrush.raster(strokes:[path],width:width,height:height,diameterFraction:Double(outerRadius*2*min(sx,sy))/Double(min(width,height)),feather:0)
        let repaired = try ContentRepairService.shared.process(rgba:PortableInpainting.straightRGBA(fromPremultiplied:bytes),mask:modelMask,width:width,height:height)
        guard let provider = CGDataProvider(data:PortableInpainting.premultipliedRGBA(fromStraight:repaired) as CFData), let bitmap = CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:sRGB,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else {throw Failure.kernel}
        generated = CIImage(cgImage:bitmap).clampedToExtent().transformed(by:CGAffineTransform(scaleX:1/sx,y:1/sy)).transformed(by:CGAffineTransform(translationX:roi.minX,y:roi.minY))
        generatedInpaint = (image,key,generated)
        }
        let coverage = try mask(points:positions,radius:outerRadius,feather:stroke.algorithmVersion>=3 ? featherWidth/outerRadius:stroke.feather,region:target,version:2)
        guard let patch = inpaintingKernel?.apply(extent:target,arguments:[image,generated,coverage,min(1,max(0,stroke.opacity))]),
              let baked = context.createCGImage(patch,from:target,format:.RGBAh,colorSpace:space) else {throw Failure.kernel}
        let local = CIImage(cgImage:baked).transformed(by:CGAffineTransform(translationX:target.minX,y:target.minY))
        guard let result=patchBlendKernel?.apply(extent:image.extent,arguments:[local.clampedToExtent(),image,CIImage(color:.white).cropped(to:target)]) else {throw Failure.kernel}
        return result
    }
    private func mask(points:[CGPoint],radius:CGFloat,feather:Double,region:CGRect,version:Int) throws -> CIImage {
        let w=Int(region.width),h=Int(region.height)
        if version>=2 {
            let local=points.map {UnitPoint2D(x:($0.x-region.minX)/region.width,y:(region.maxY-$0.y)/region.height)}
            let data=PortableBrush.raster(strokes:[local],width:w,height:h,diameterFraction:2*radius/min(region.width,region.height),feather:feather)
            guard !data.isEmpty,let provider=CGDataProvider(data:data as CFData),let bitmap=CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:w,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.none.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else {throw Failure.invalid}
            return CIImage(cgImage:bitmap,options:[.colorSpace:NSNull()]).transformed(by:CGAffineTransform(translationX:region.minX,y:region.minY))
        }
        var data=[UInt8](repeating:0,count:w*h)
        let result=data.withUnsafeMutableBytes { bytes -> Bool in
            guard let cg=CGContext(data:bytes.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue) else {return false}
            cg.translateBy(x:-region.minX,y:-region.minY)
            cg.setStrokeColor(gray:1,alpha:1);cg.setFillColor(gray:1,alpha:1)
            cg.setLineWidth(radius*2);cg.setLineCap(.round);cg.setLineJoin(.round)
            if points.count==1 {cg.fillEllipse(in:CGRect(x:points[0].x-radius,y:points[0].y-radius,width:radius*2,height:radius*2))}
            else {cg.addLines(between:points);cg.strokePath()}
            return true
        }
        guard result,let provider=CGDataProvider(data:Data(data) as CFData), let bitmap=CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:w,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.none.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else {throw Failure.invalid}
        var image=CIImage(cgImage:bitmap,options:[.colorSpace:NSNull()]).transformed(by:CGAffineTransform(translationX:region.minX,y:region.minY))
        let blur=radius*CGFloat(min(1,max(0,feather)))*0.32
        if blur>0.1 {image=image.applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:blur]).cropped(to:region)}
        return image
    }
    /// Solve a smooth target-minus-source correction with known values outside
    /// the repair. The source carries full-resolution texture; only this smooth
    /// field is solved at a bounded resolution, with coarse-to-fine relaxation.
    private func harmonicCorrection(target:CIImage,source:CIImage,mask:CIImage,region:CGRect,radius:Double,version:Int) throws -> CIImage {
        let factor=min(1,192/max(region.width,region.height))
        let size=version>=2 ? PortableHealing.correctionSize(width:region.width,height:region.height,radius:radius):(max(3,Int(ceil(region.width*factor))),max(3,Int(ceil(region.height*factor))))
        let (w,h)=size
        func samples(_ image:CIImage)->[Float] {
            let scaled=image.cropped(to:region).transformed(by:CGAffineTransform(translationX:-region.minX,y:-region.minY)).transformed(by:CGAffineTransform(scaleX:CGFloat(w)/region.width,y:CGFloat(h)/region.height))
            var pixels=[Float](repeating:0,count:w*h*4)
            pixels.withUnsafeMutableBytes {context.render(scaled,toBitmap:$0.baseAddress!,rowBytes:w*16,bounds:CGRect(x:0,y:0,width:w,height:h),format:.RGBAf,colorSpace:space)}
            return pixels
        }
        let a=samples(target), b=samples(source), m=samples(mask)
        var diff=[Float](repeating:0,count:w*h*4), unknown=[Bool](repeating:false,count:w*h)
        for i in 0..<w*h {
            for c in 0..<3 {diff[i*4+c]=a[i*4+c]-b[i*4+c]}
            diff[i*4+3]=1
            unknown[i]=m[i*4]>0.015 && i%w>0 && i%w<w-1 && i/w>0 && i/w<h-1
        }
        let solved=version>=3 ? PortableHealing.solveBiharmonic(diff:diff,unknown:unknown,width:w,height:h):PortableHealing.solve(diff:diff,unknown:unknown,width:w,height:h)
        let data=solved.withUnsafeBytes {Data($0)}
        return CIImage(bitmapData:data,bytesPerRow:w*16,size:CGSize(width:w,height:h),format:.RGBAf,colorSpace:space)
            .transformed(by:CGAffineTransform(scaleX:region.width/CGFloat(w),y:region.height/CGFloat(h)))
            .transformed(by:CGAffineTransform(translationX:region.minX,y:region.minY)).clampedToExtent()
    }
    /// Core Image is only an input adapter; matching itself is portable.
    func findSource(for stroke:RepairStroke,in image:CIImage,variant:Int=0) throws -> UnitPoint2D {
        let bounds=image.extent,f=min(1,1280/max(bounds.width,bounds.height))
        let w=max(1,Int(bounds.width*f)),h=max(1,Int(bounds.height*f))
        let small=image.transformed(by:CGAffineTransform(translationX:-bounds.minX,y:-bounds.minY)).transformed(by:CGAffineTransform(scaleX:CGFloat(w)/bounds.width,y:CGFloat(h)/bounds.height))
        var pixels=[UInt8](repeating:0,count:w*h*4)
        pixels.withUnsafeMutableBytes {context.render(small,toBitmap:$0.baseAddress!,rowBytes:w*4,bounds:CGRect(x:0,y:0,width:w,height:h),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)}
        guard let result=PortableHealing.findSource(pixels:pixels,width:w,height:h,points:stroke.points,radius:stroke.radius*Double(min(w,h)),variant:variant) else {throw Failure.invalid}
        return result
    }
}
