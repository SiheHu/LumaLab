import LumaDomain
import AppKit
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CoreText

/// An independent Core Image pipeline; its controls approximate photographic adjustments.
final class ImagePipeline {
    enum PipelineError: LocalizedError {
        case invalidImage, renderFailed, exportFailed
        var errorDescription: String? {
            switch self {
            case .invalidImage: return "无法解码这张 image，请选择支持的 image 格式。"
            case .renderFailed: return "无法 render 这张 image。"
            case .exportFailed: return "无法 export 这张 image。"
            }
        }
    }

    let repairProcessor=RepairProcessor()
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let context: CIContext
    private let overlayTintKernel = CIColorKernel(source: """
    kernel vec4 overlayTint(__sample mask, vec3 color, float opacity) {
        float a=clamp(mask.r,0.0,1.0)*opacity;
        return vec4(color*a,a);
    }
    """)
    private let cubeLock = NSLock()
    private var cubeCache: (key: Data, cube: Data)?
    private var localHSLCubes: [UUID:(bands:[HSLBand],data:Data)] = [:]
    private let geometryLock = NSLock()
    private var geometryCache: (source:CIImage, settings:GeometrySettings, turns:Int, flip:Bool, distortion:Double, region:CropRegion)?
    private let subtractKernel = CIColorKernel(source: "kernel vec4 subMask(__sample a, __sample b) { return vec4(vec3(max(a.r-b.r,0.0)),1.0); }")
    private let eraseKernel = CIColorKernel(source: "kernel vec4 eraseMask(__sample a, __sample b) { return vec4(vec3(a.r * (1.0-clamp(b.r,0.0,1.0))),1.0); }")
    private let intersectKernel = CIColorKernel(source: "kernel vec4 intersectMask(__sample a, __sample b) { return vec4(vec3(min(a.r,b.r)),1.0); }")
    private let maskedExposureKernel = CIColorKernel(source: "kernel vec4 maskedExposure(__sample image, __sample mask, float ev) { return vec4(image.rgb * pow(2.0, ev * clamp(mask.r, 0.0, 3.0)), image.a); }")


    private let strengthBlendKernel = CIColorKernel(source: "kernel vec4 strengthBlend(__sample front, __sample back, __sample mask) { return vec4(mix(back.rgb, front.rgb, clamp(mask.r,0.0,3.0)), back.a); }")
    private let grainKernel = CIColorKernel(source: """
    kernel vec4 neutralGrain(__sample image, float quantity, float grainSize, float roughness) {
        vec4 c = unpremultiply(image);
        vec3 rgb = max(c.rgb,vec3(0.0));
        vec3 encoded = mix(rgb * 12.92,1.055 * pow(rgb,vec3(1.0/2.4)) - 0.055,step(vec3(0.0031308),rgb));
        vec2 cell = floor(destCoord()/max(0.5,grainSize));
        float noise = fract(sin(dot(cell,vec2(12.9898,78.233))) * 43758.5453) - 0.5;
        encoded = max(vec3(0.0),encoded + vec3(noise * quantity * (0.5 + roughness * 0.5) * 0.08));
        vec3 linear = mix(encoded/12.92,pow((encoded+0.055)/1.055,vec3(2.4)),step(vec3(0.04045),encoded));
        return premultiply(vec4(linear,c.a));
    }
    """)

    init() {
        context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                      .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      .cacheIntermediates: false])
    }

    func load(data: Data) throws -> CIImage {
        return try PhotoIO.decode(data: data).image
    }

    func render(source: CIImage, edits: EditState, maxDimension: CGFloat? = nil, applyCrop: Bool = true) throws -> CGImage {
        let image = try processed(source: source, edits: edits, maxDimension: maxDimension, applyCrop: applyCrop)
        guard let result = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colorSpace) else { throw PipelineError.renderFailed }
        return result
    }

    func proofSource(source:CIImage,edits:EditState,maxDimension:CGFloat?=nil,applyCrop:Bool=true) throws -> CGImage {
        let image=try processed(source:source,edits:edits,maxDimension:maxDimension,applyCrop:applyCrop)
        guard let cg=context.createCGImage(image,from:image.extent,format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.linearSRGB)) else {throw PipelineError.renderFailed}
        return cg
    }

    /// The viewport uses full-resolution dimensions even while displaying a proxy.
    func outputSize(source: CIImage, edits: EditState, applyCrop: Bool = true) throws -> CGSize {
        let edits = edits.renderingState
        var size = source.extent.size
        if abs(edits.quarterTurns % 2) == 1 { size = CGSize(width: size.height, height: size.width) }

        if applyCrop && !edits.crop.isFull { size = cropRect(edits.crop, in: size).size }
        return CGSize(width: max(1, floor(size.width + 0.00001)), height: max(1, floor(size.height + 0.00001)))
    }

    private func processed(source: CIImage, edits: EditState, maxDimension: CGFloat? = nil, applyCrop: Bool = true) throws -> CIImage {
        let edits = edits.renderingState
        let automatic = try autoCropRegion(source:source,edits:edits)
        var image = normalized(try repairProcessor.apply(source:source,strokes:edits.repairs))
        guard image.extent.width.isFinite, image.extent.height.isFinite,
              image.extent.width >= 1, image.extent.height >= 1 else { throw PipelineError.invalidImage }
        if let limit = maxDimension, limit.isFinite, limit >= 1 {
            let factor = min(1, limit / max(image.extent.width, image.extent.height))
            if factor < 1 {
                let width=max(1,floor(image.extent.width*factor)),height=max(1,floor(image.extent.height*factor))
                // Resolve edge sampling before resizing and use exact proxy bounds.
                // Fractional crop edges otherwise receive different alpha weights
                // when a local repair adds an extra stage to the image graph.
                image=image.clampedToExtent().transformed(by:CGAffineTransform(scaleX:width/image.extent.width,y:height/image.extent.height))
                    .cropped(to:CGRect(x:0,y:0,width:width,height:height))
            }
        }
        let bounds = image.extent
        let original = image
        image = adjusted(image, edits.adjustments)
        if edits.curves != CurveSettings() || edits.hsl != HSLBand.defaults || edits.grading != ColorGrading() || edits.pointColor != PointColorSettings() || edits.calibration != CalibrationSettings() {
            var colorEdits = edits; colorEdits.adjustments = .neutral; colorEdits.masks = []; colorEdits.repairs = []; colorEdits.geometry = GeometrySettings(); colorEdits.crop = .full
            colorEdits.quarterTurns = 0; colorEdits.flipHorizontal = false
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let key = (try? encoder.encode(colorEdits)) ?? Data()
            let cube: Data
            cubeLock.lock(); let cached = cubeCache; cubeLock.unlock()
            if let cached = cached, cached.key == key { cube = cached.cube }
            else {
                let prepared = PreparedColorTransform(colorEdits)
                cube = EngineColor.cube { prepared.apply($0, $1, $2) }
                cubeLock.lock(); cubeCache = (key, cube); cubeLock.unlock()
            }
            image = colorCube(image, data: cube)
        }
        if let cube = edits.lut.cube, edits.lut.enabled, edits.lut.amount > 0, cube.isValid {
            let amount = min(2,max(0,edits.lut.amount))
            let data = EngineColor.cube { r,g,b in
                let v = cube.apply(r,g,b)
                return (r+(v.0-r)*amount,g+(v.1-g)*amount,b+(v.2-b)*amount)
            }
            image = colorCube(image,data:data)
        }
        for mask in edits.masks where mask.enabled && mask.opacity > 0 && (mask.adjustments != .neutral || mask.hsl != HSLBand.defaults) {
            let selection = maskImage(mask, size: bounds.size, source: original)
            var local = mask.adjustments
            let exposure = safe(local.exposure, -15, 15)
            local.exposure = 0
            var foreground = vignette(adjusted(image, local), adjustments: local)
            if mask.hsl != HSLBand.defaults {
                cubeLock.lock();let cached=localHSLCubes[mask.id];cubeLock.unlock()
                let data:Data
                if let cached=cached,cached.bands==mask.hsl {data=cached.data}
                else {
                    var settings=EditState();settings.hsl=mask.hsl
                    let transform=PreparedColorTransform(settings)
                    data=EngineColor.cube {transform.apply($0,$1,$2)}
                    cubeLock.lock();if localHSLCubes.count>=8 {localHSLCubes.removeAll()};localHSLCubes[mask.id]=(mask.hsl,data);cubeLock.unlock()
                }
                foreground=colorCube(foreground,data:data)
            }
            guard let blended = strengthBlendKernel?.apply(extent:bounds,arguments:[foreground,image,selection]) else {throw PipelineError.renderFailed}
            image = blended
            if exposure != 0 {
                // Interpolate stops, rather than mixing an already overexposed
                // foreground. A 50% mask at +2 EV therefore applies +1 EV.
                guard let exposed = maskedExposureKernel?.apply(extent: bounds, arguments: [image, selection, exposure]) else { throw PipelineError.renderFailed }
                image = exposed
            }
        }
        let turns = ((edits.quarterTurns % 4) + 4) % 4
        if turns != 0 { image = normalized(image.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(turns) * .pi / 2))) }
        if edits.flipHorizontal {
            image = normalized(image.transformed(by: CGAffineTransform(scaleX: -1, y: 1)))
        }
        image = geometry(image, settings: edits.geometry)
        if edits.geometry.autoCrop {
            let canvas=image.extent
            let region=cropRect(automatic,in:canvas.size)
            let selected=normalized(image.cropped(to:region))
            image=selected.clampedToExtent().transformed(by:CGAffineTransform(scaleX:canvas.width/selected.extent.width,y:canvas.height/selected.extent.height)).cropped(to:canvas)
        }
        if applyCrop && !edits.crop.isFull {
            let rect = cropRect(edits.crop, in: image.extent.size)
            image = normalized(image.cropped(to: rect))
        }
        let extent = image.extent
        // Integral output dimensions prevent fractional-edge transparency after transforms.
        let output = CGRect(x: 0, y: 0, width: max(1, floor(extent.width + 0.00001)), height: max(1, floor(extent.height + 0.00001)))
        image = image.cropped(to: output)
        return vignette(image, adjustments: edits.adjustments)
    }

    func maskImage(_ mask: LocalMask, size: CGSize, source: CIImage? = nil) -> CIImage {
        var base = mask; base.opacity = 1; base.inverted = false; base.components = []
        var result = primitiveMask(base, size: size, source: source)
        for component in mask.components {
            var item = LocalMask(name: "", kind: component.kind)
            item.raster = component.raster; item.edgeStrokes = component.edgeStrokes; item.brushVersion = component.brushVersion
            item.feather = component.feather; item.brushSize = component.brushSize
            item.start = component.start; item.end = component.end; item.strokes = component.strokes
            item.erasedStrokes = component.erasedStrokes; item.flow = component.flow; item.density = component.density
            item.rangeColor = component.rangeColor; item.rangeTolerance = component.rangeTolerance
            item.luminanceLow = component.luminanceLow; item.luminanceHigh = component.luminanceHigh
            let primitive = primitiveMask(item, size: size, source: source)
            let operand = component.inverted ? scalarMask(primitive, factor: -1, bias: 1) : primitive
            switch component.operation {
            case .add: result = result.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: operand])
            case .subtract: result = subtractKernel?.apply(extent: result.extent, arguments: [result, operand]) ?? result
            case .intersect: result = intersectKernel?.apply(extent: result.extent, arguments: [result, operand]) ?? result
            }
        }
        let opacity = safe(mask.opacity, 0, 3)
        return scalarMask(result, factor: mask.inverted ? -opacity : opacity, bias: mask.inverted ? opacity : 0)
    }

    func selectionOverlay(_ mask: LocalMask, source: CIImage, maxDimension: CGFloat = 1600) throws -> CGImage {
        try selectionOverlays([(mask, 0.48)], source: source, maxDimension: maxDimension)
    }
    func selectionOverlays(_ layers: [(mask: LocalMask, alpha: Double)], source: CIImage, maxDimension: CGFloat = 1600) throws -> CGImage {
        let source = normalized(source)
        let scale = min(1, max(1, maxDimension) / max(source.extent.width, source.extent.height))
        let preview = normalized(source.transformed(by: CGAffineTransform(scaleX: scale, y: scale)))
        var overlay = CIImage(color: .clear).cropped(to: preview.extent)
        for layer in layers {
            let selection = maskImage(layer.mask, size: preview.extent.size, source: preview)
            let color = layer.mask.overlayColor.count == 3 ? layer.mask.overlayColor : [1,0.12,0.10]
            let tint=CIVector(x:safe(color[0],0,1),y:safe(color[1],0,1),z:safe(color[2],0,1))
            guard let colored=overlayTintKernel?.apply(extent:preview.extent,arguments:[selection,tint,safe(layer.alpha,0,1)]) else {throw PipelineError.renderFailed}
            overlay = colored.composited(over:overlay)
        }
        guard let image = context.createCGImage(overlay, from: preview.extent, format: .RGBA8, colorSpace: colorSpace) else { throw PipelineError.renderFailed }
        return image
    }

    func coveragePreview(_ mask: LocalMask, source: CIImage, maxDimension: CGFloat = 1600) throws -> CGImage {
        let scale=min(1,maxDimension/max(source.extent.width,source.extent.height))
        let preview=normalized(source.transformed(by:CGAffineTransform(scaleX:scale,y:scale)))
        let image=maskImage(mask,size:preview.extent.size,source:preview)
        guard let cg=context.createCGImage(image,from:preview.extent,format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB()) else {throw PipelineError.renderFailed}
        return cg
    }
    func sampledRGB(source: CIImage, point: UnitPoint2D) -> [Double] {
        let x=min(source.extent.width-1,max(0,point.x*source.extent.width))
        let y=min(source.extent.height-1,max(0,(1-point.y)*source.extent.height))
        var pixel=[UInt8](repeating:0,count:4)
        context.render(source,toBitmap:&pixel,rowBytes:4,bounds:CGRect(x:x,y:y,width:1,height:1),format:.RGBA8,colorSpace:colorSpace)
        return pixel.prefix(3).map {Double($0)/255}
    }
    private func primitiveMask(_ mask: LocalMask, size: CGSize, source: CIImage?, centeredGradient: Bool = true) -> CIImage {
        if mask.kind == .automatic {
            let bounds = CGRect(origin: .zero, size: size)
            guard let raster = mask.raster, raster.isValid,
                  let provider = CGDataProvider(data: raster.pixels as CFData),
                  let bitmap = CGImage(width: raster.width, height: raster.height, bitsPerComponent: 8, bitsPerPixel: 8,
                    bytesPerRow: raster.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
                return CIImage(color: .black).cropped(to: bounds)
            }
            return CIImage(cgImage: bitmap, options: [.colorSpace: NSNull()])
                .clampedToExtent().transformed(by: CGAffineTransform(scaleX: size.width / CGFloat(raster.width), y: size.height / CGFloat(raster.height)))
                .cropped(to: bounds)
        }
        // Raster dimensions are capped at 32768; the selection is scaled back to
        // the requested extent, keeping normalized geometry on larger inputs.
        let width = max(1, Int(min(32768, size.width.isFinite ? size.width : 1)))
        let height = max(1, Int(min(32768, size.height.isFinite ? size.height : 1)))
        if mask.kind == .colorRange || mask.kind == .luminanceRange {
            guard let source = source else { return CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: width, height: height)) }
            let palette = mask.rangeColor.count >= 3 ? mask.rangeColor : [0.5, 0.5, 0.5]
            let data = EngineColor.cube { r, g, b in
                let value: Double
                if mask.kind == .colorRange {
                    let distance = sqrt(pow(r-palette[0],2)+pow(g-palette[1],2)+pow(b-palette[2],2)) / sqrt(3)
                    value = 1 - EngineColor.smooth(distance / max(0.005, mask.rangeTolerance))
                } else {
                    let light = 0.2126*r + 0.7152*g + 0.0722*b
                    let low = min(mask.luminanceLow, mask.luminanceHigh), high = max(mask.luminanceLow, mask.luminanceHigh)
                    let softness = max(0.005, safe(mask.feather, 0, 3) * 0.25)
                    value = EngineColor.smooth((light-low+softness)/softness) * (1-EngineColor.smooth((light-high)/softness))
                }
                return (value,value,value)
            }
            return colorCube(source, data: data).cropped(to: source.extent)
        }
        let gray = CGColorSpaceCreateDeviceGray()
        let feather = safe(mask.feather, 0, 3)
        let sx = safe(mask.start.x, -4, 5) * Double(width)
        let sy = safe(mask.start.y, -4, 5) * Double(height)
        let ex = safe(mask.end.x, -4, 5) * Double(width)
        let ey = safe(mask.end.y, -4, 5) * Double(height)
        var bytes = [UInt8](repeating: 0, count: width * height)
        if mask.kind == .brush, (mask.brushVersion ?? 1) >= 2 {
            bytes = [UInt8](PortableBrush.raster(strokes: mask.strokes, width: width, height: height, diameterFraction: mask.brushSize, feather: min(1, feather)))
        } else if mask.kind == .brush {
            bytes.withUnsafeMutableBytes { storage in
                guard let cg = CGContext(data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                         bytesPerRow: width, space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
                cg.translateBy(x: 0, y: CGFloat(height)); cg.scaleBy(x: 1, y: -1)
                cg.setStrokeColor(gray: 1, alpha: 1); cg.setFillColor(gray: 1, alpha: 1)
                // Binary coverage is unioned before one feather pass: repeated
                // strokes cannot accumulate antialias alpha or adjustment strength.
                cg.setShouldAntialias(false)
                cg.setLineCap(.round); cg.setLineJoin(.round)
                let diameter = max(1, safe(mask.brushSize, 0.001, 3) * Double(min(width, height)))
                cg.setLineWidth(diameter)
                for stroke in mask.strokes where !stroke.isEmpty {
                    let points = stroke.map { CGPoint(x: safe($0.x, 0, 1) * Double(width), y: safe($0.y, 0, 1) * Double(height)) }
                    if points.count == 1 {
                        cg.fillEllipse(in: CGRect(x: points[0].x - diameter / 2, y: points[0].y - diameter / 2, width: diameter, height: diameter))
                    } else {
                        cg.beginPath(); cg.addLines(between: points); cg.strokePath()
                    }
                }
            }
        } else {
            let dx = ex - sx, dy = ey - sy
            let cx = (sx + ex) / 2, cy = (sy + ey) / 2
            let rx = max(0.5, abs(dx) / 2), ry = max(0.5, abs(dy) / 2)
            for y in 0..<height {
                for x in 0..<width {
                    let px = Double(x) + 0.5, py = Double(y) + 0.5
                    let value: Double
                    switch mask.kind {
                    case .linear:
                        let length = max(0.0001, dx * dx + dy * dy)
                        let t = ((px - sx) * dx + (py - sy) * dy) / length
                        let span = max(0.005, feather)
                        value = 1 - smooth((t - (0.5 - span / 2)) / span)
                    case .radial:
                        let distance = hypot((px - cx) / rx, (py - cy) / ry)
                        if centeredGradient {
                            // No flat interior: the whole radius participates. At
                            // the default setting, coverage falls linearly to zero.
                            value = pow(max(0, 1 - distance), pow(2, (0.75 - feather) * 2))
                        } else {
                            value = 1 - smooth((distance - (1 - feather)) / max(0.005, feather))
                        }
                    case .rectangle:
                        // Separable tent functions avoid the diagonal derivative
                        // seams produced by minimum-distance rectangle feathering.
                        let horizontal = max(0, 1 - abs(px - cx) / rx)
                        let vertical = max(0, 1 - abs(py - cy) / ry)
                        value = pow(horizontal * vertical, pow(2, (0.75 - feather) * 2))
                    case .brush, .colorRange, .luminanceRange, .automatic: value = 0
                    }
                    bytes[y * width + x] = UInt8((safe(value, 0, 1) * 255).rounded())
                }
            }
        }
        if mask.kind == .brush, !mask.edgeStrokes.isEmpty, let source {
            let src = normalized(source).transformed(by:CGAffineTransform(scaleX:CGFloat(width)/source.extent.width,y:CGFloat(height)/source.extent.height))
            if let bitmap = context.createCGImage(src,from:CGRect(x:0,y:0,width:width,height:height),format:.RGBA8,colorSpace:colorSpace), let data=bitmap.dataProvider?.data {
                let raw=[UInt8](data as Data)
                var rgba=[UInt8](repeating:0,count:width*height*4)
                for y in 0..<height {rgba.replaceSubrange(y*width*4..<(y+1)*width*4,with:raw[y*bitmap.bytesPerRow..<y*bitmap.bytesPerRow+width*4])}
                for stroke in mask.edgeStrokes {
                    let coverage=EdgeAwareBrush.coverage(stroke,rgba:rgba,width:width,height:height)
                    guard coverage.count==bytes.count else {continue}
                    for i in bytes.indices {bytes[i] = stroke.erase ? UInt8(Double(bytes[i])*(1-Double(coverage[i])/255)) : max(bytes[i],coverage[i])}
                }
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let raster = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                             space: gray, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                             decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        // Coverage is a scalar, not a gamma-encoded photograph.
        var image = CIImage(cgImage: raster, options: [.colorSpace: NSNull()])
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        if mask.kind == .brush && (mask.brushVersion ?? 1) == 1 && feather > 0 {
            let blur = max(0.2, safe(mask.brushSize, 0.001, 3) * Double(min(width, height)) * feather * 0.22)
            image = image.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur]).cropped(to: bounds)
        }
        if mask.kind == .brush {
            image = scalarMask(image, factor: min(safe(mask.flow,0,3), safe(mask.density,0,3)), bias: 0)
            if !mask.erasedStrokes.isEmpty {
                var eraser = mask; eraser.strokes = mask.erasedStrokes; eraser.erasedStrokes = []; eraser.edgeStrokes = []; eraser.flow = 1; eraser.density = 1
                let erase = primitiveMask(eraser, size: CGSize(width: width,height:height), source: source)
                image = eraseKernel?.apply(extent: bounds, arguments: [image,erase]) ?? image
            }
        }
        let factor = 1.0, bias = 0.0
        let result = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: factor, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: factor, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: factor, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)
        ]).cropped(to: bounds)
        // A preview can have a fractional extent after scaling. Stretch the raster by
        // that subpixel remainder, preserving normalized mask geometry at every size.
        let requestedWidth = size.width.isFinite ? max(1, size.width) : 1
        let requestedHeight = size.height.isFinite ? max(1, size.height) : 1
        return result.transformed(by: CGAffineTransform(scaleX: requestedWidth / CGFloat(width),
                                                        y: requestedHeight / CGFloat(height)))
            .cropped(to: CGRect(x: 0, y: 0, width: requestedWidth, height: requestedHeight))
    }

    /// Samples the actual pointwise color pipeline, avoiding spatial operations.
    func globalColorLUT(edits: EditState, size: Int = 33) throws -> CubeLUT {
        guard (2...65).contains(size) else { throw PipelineError.exportFailed }
        let state = edits.lutExportState
        let width = size * size, height = size
        var pixels = [Float](); pixels.reserveCapacity(size * size * size * 4)
        for b in 0..<size { for g in 0..<size { for r in 0..<size {
            pixels += [Float(r)/Float(size-1), Float(g)/Float(size-1), Float(b)/Float(size-1), 1]
        } } }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let atlas = CIImage(bitmapData: data, bytesPerRow: width*16, size: CGSize(width:width,height:height), format:.RGBAf, colorSpace:colorSpace)
        let image = try processed(source:atlas,edits:state)
        var output = [Float](repeating:0,count:pixels.count)
        output.withUnsafeMutableBytes { bytes in
            context.render(image,toBitmap:bytes.baseAddress!,rowBytes:width*16,bounds:CGRect(x:0,y:0,width:width,height:height),format:.RGBAf,colorSpace:colorSpace)
        }
        var values = [Float](); values.reserveCapacity(size*size*size*3)
        for i in stride(from:0,to:output.count,by:4) { values += (0..<3).map { Float(EngineColor.clamp(Double(output[i+$0]))) } }
        return try CubeLUT(name:"LumaLab",size:size,values:values)
    }

    func scopeAnalysis(_ image: CGImage) -> ScopeAnalysis {
        let factor = min(1,320/Double(max(image.width,image.height)))
        let w = max(1,Int(Double(image.width)*factor)), h = max(1,Int(Double(image.height)*factor))
        var bytes = [UInt8](repeating:0,count:w*h*4)
        bytes.withUnsafeMutableBytes { storage in
            if let cg = CGContext(data:storage.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:colorSpace,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) {
                cg.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
            }
        }
        return ScopeAnalysis.analyze(rgba:bytes,width:w,height:h)
    }

    func estimateExport(source: CIImage, edits: EditState, options: ExportOptions, metadata: [String:Any]) throws -> Int64 {
        let size = try outputSize(source:source,edits:edits)
        let longest = max(size.width,size.height)
        let factor = options.longEdge > 0 ? (options.dontEnlarge ? min(1,CGFloat(options.longEdge)/longest) : CGFloat(options.longEdge)/longest) : 1
        let target = max(1,floor(size.width*factor))*max(1,floor(size.height*factor))
        guard target.isFinite, target <= 100_000_000 else { throw PipelineError.exportFailed }
        if longest*factor <= 1024 {
            return Int64(try export(source:source,edits:edits,options:options,metadata:metadata).count)
        }
        var sample = options
        let limit = min(1024,longest*factor)
        sample.longEdge = Int(limit); sample.dontEnlarge = false
        let encoded = try export(source:source,edits:edits,options:sample,metadata:metadata,maxDimension:limit)
        // Metadata is a fixed overhead; measure it with the same encoder instead
        // of multiplying it by the full-photo area ratio.
        var plain = sample; plain.includeMetadata = false
        let withoutMetadata = try export(source:source,edits:edits,options:plain,maxDimension:limit)
        let overhead = max(0,encoded.count-withoutMetadata.count)
        let samplePixels = max(1,floor(size.width*limit/longest))*max(1,floor(size.height*limit/longest))
        let value = Double(overhead)+Double(withoutMetadata.count)*target/samplePixels
        guard value.isFinite, value < Double(Int64.max) else { throw PipelineError.exportFailed }
        return Int64(value.rounded())
    }

    func exportPNG(source: CIImage, edits: EditState) throws -> Data {
        var options = ExportOptions(); options.format = .png
        return try export(source:source,edits:edits,options:options)
    }

    func exportJPEG(source: CIImage, edits: EditState, quality: Double = 0.95) throws -> Data {
        var options = ExportOptions(); options.format = .jpeg; options.quality = quality
        return try export(source:source,edits:edits,options:options)
    }

    func histogram(_ image: CGImage) -> [[Double]] {
        let width = min(256, image.width), height = max(1, Int(Double(image.height) * Double(width) / Double(image.width)))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var channels = [[Double]](repeating: [Double](repeating: 0, count: 256), count: 3)
        pixels.withUnsafeMutableBytes { bytes in
            guard let cg = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: width * 4, space: colorSpace,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            cg.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        for offset in stride(from: 0, to: pixels.count, by: 4) where pixels[offset + 3] > 0 {
            for channel in 0..<3 { channels[channel][Int(pixels[offset + channel])] += 1 }
        }
        let peak = max(1, channels.flatMap { $0 }.max() ?? 1)
        return channels.map { $0.map { $0 / peak } }
    }

    private func adjusted(_ source: CIImage, _ a: Adjustments) -> CIImage {
        if a == .neutral { return source }
        let bounds = source.extent
        var image = source
        if a.exposure != 0 { image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: safe(a.exposure, -15, 15)]) }
        if a.temperature != 0 || a.tint != 0 {
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: max(1000,6500 + safe(a.temperature, -300, 300) * 30), y: 0),
                "inputTargetNeutral": CIVector(x: 6500, y: -safe(a.tint, -300, 300) * 0.6)])
        }
        if a.shadows != 0 {
            image = image.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": 1,
                                                                              "inputShadowAmount": safe(a.shadows, -300, 300) / 100,
                                                                              "inputRadius": 0])
        }
        if a.highlights != 0 {
            // The built-in highlight control only darkens. A signed upper-tone curve
            // gives this editor's Highlights slider a consistent lift/recover direction.
            let amount = safe(a.highlights, -300, 300) / 100
            image = image.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0.25, y: 0.25),
                "inputPoint2": CIVector(x: 0.5, y: 0.5 + amount * 0.02),
                "inputPoint3": CIVector(x: 0.75, y: 0.75 + amount * 0.12),
                "inputPoint4": CIVector(x: 1, y: 1)])
        }
        if a.whites != 0 || a.blacks != 0 {
            let white = safe(a.whites, -300, 300) / 500, black = safe(a.blacks, -300, 300) / 500
            image = image.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: black), "inputPoint1": CIVector(x: 0.25, y: 0.25 + black * 0.55),
                "inputPoint2": CIVector(x: 0.5, y: 0.5), "inputPoint3": CIVector(x: 0.75, y: 0.75 + white * 0.55),
                "inputPoint4": CIVector(x: 1, y: 1 + white)])
        }
        if a.contrast != 0 || a.saturation != 0 {
            image = image.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1 + safe(a.contrast, -300, 300) * 3 / 10000,
                                                                       kCIInputSaturationKey: 1 + safe(a.saturation, -300, 300) / 100])
        }
        if a.vibrance != 0 { image = image.applyingFilter("CIVibrance", parameters: [kCIInputAmountKey: safe(a.vibrance, -300, 300) / 100]) }
        if a.clarity > 0 {
            image = image.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: max(1, min(bounds.width, bounds.height) * 0.012),
                                                                                      kCIInputIntensityKey: safe(a.clarity, 0, 300) / 100]).cropped(to: bounds)
        } else if a.clarity < 0 {
            let soft = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(1, min(bounds.width, bounds.height) * 0.004)]).cropped(to: bounds)
            image = image.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: soft, kCIInputTimeKey: -safe(a.clarity, -300, 0) / 160])
        }
        if a.texture != 0 {
            if a.texture > 0 { image = image.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: max(0.5,min(bounds.width,bounds.height)/1000), kCIInputIntensityKey: safe(a.texture, 0, 300)/70]).cropped(to: bounds) }
            else { let soft = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(0.5,min(bounds.width,bounds.height)/1000)]).cropped(to: bounds); image = image.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: soft,kCIInputTimeKey: -a.texture/130]) }
        }
        if a.dehaze != 0 {
            let amount = safe(a.dehaze, -300, 300)/1000
            image = image.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1+amount*0.3,kCIInputSaturationKey: 1+amount*0.12,kCIInputBrightnessKey: -amount*0.025])
        }
        if a.noiseReduction > 0 {
            let reduced = image.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": safe(a.noiseReduction, 0, 300)/700,"inputSharpness":0]).cropped(to:bounds)
            image = reduced.applyingFilter("CILuminosityBlendMode",parameters:[kCIInputBackgroundImageKey:image])
        }
        if a.colorNoiseReduction > 0 {
            let blurred = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.5+safe(a.colorNoiseReduction, 0, 300)/18]).cropped(to:bounds)
            let colored = blurred.applyingFilter("CIColorBlendMode", parameters:[kCIInputBackgroundImageKey:image])
            image = image.applyingFilter("CIDissolveTransition", parameters:[kCIInputTargetImageKey:colored,kCIInputTimeKey:safe(a.colorNoiseReduction, 0, 300)/100])
        }
        if a.sharpness > 0 {
            let sharp = image.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: safe(a.sharpenRadius,0.1,9),kCIInputIntensityKey:safe(a.sharpness, 0, 300)/60*(0.5+safe(a.sharpenDetail, 0, 300)/100)]).cropped(to:bounds)
            if a.sharpenMasking > 0 {
                let edges = image.applyingFilter("CIEdges",parameters:[kCIInputIntensityKey:4]).applyingFilter("CIColorControls",parameters:[kCIInputSaturationKey:0,kCIInputContrastKey:1+safe(a.sharpenMasking, 0, 300)/10,kCIInputBrightnessKey:-safe(a.sharpenMasking, 0, 300)/400])
                image = sharp.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:image,kCIInputMaskImageKey:edges])
            } else { image = sharp }
        }
        if a.defringe > 0 {
            let strength = safe(a.defringe, 0, 300)/100
            let data = EngineColor.cube { r,g,b in
                let hsl = EngineColor.hsl(r,g,b)
                let weight = max(EngineColor.smooth(1-EngineColor.hueDistance(hsl.0,0.82)/0.15),EngineColor.smooth(1-EngineColor.hueDistance(hsl.0,0.33)/0.13))
                return EngineColor.rgb(hsl.0,hsl.1*(1-weight*strength*0.85),hsl.2)
            }
            let reduced = colorCube(image,data:data)
            let edges = image.applyingFilter("CIEdges",parameters:[kCIInputIntensityKey:3]).applyingFilter("CIColorControls",parameters:[kCIInputSaturationKey:0])
            image = reduced.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:image,kCIInputMaskImageKey:edges])
        }
        if a.distortion != 0 {
            image = image.clampedToExtent().applyingFilter("CIBumpDistortion",parameters:[kCIInputCenterKey:CIVector(x:bounds.midX,y:bounds.midY),kCIInputRadiusKey:hypot(bounds.width,bounds.height)*0.65,kCIInputScaleKey:safe(a.distortion, -300, 300)/250]).cropped(to:bounds)
        }
        if a.grain > 0, let grained = grainKernel?.apply(extent:bounds,arguments:[image,safe(a.grain,0,300)/100,0.6+safe(a.grainSize,0,300)/20,safe(a.grainRoughness,0,300)/100]) {
            image = grained
        }
        return image.cropped(to: bounds)
    }

    private func colorCube(_ image: CIImage, data: Data) -> CIImage {
        image.applyingFilter("CIColorCubeWithColorSpace", parameters: ["inputCubeDimension":24,"inputCubeData":data,"inputColorSpace":colorSpace])
    }

    private func scalarMask(_ image: CIImage, factor: Double, bias: Double) -> CIImage {
        image.applyingFilter("CIColorMatrix",parameters:[
            "inputRVector":CIVector(x:factor,y:0,z:0,w:0),"inputGVector":CIVector(x:0,y:factor,z:0,w:0),
            "inputBVector":CIVector(x:0,y:0,z:factor,w:0),"inputAVector":CIVector(x:0,y:0,z:0,w:1),
            "inputBiasVector":CIVector(x:bias,y:bias,z:bias,w:0)])
    }

    private func geometry(_ source: CIImage, settings: GeometrySettings) -> CIImage {
        if settings == GeometrySettings() { return source }
        let bounds = source.extent, w = bounds.width, h = bounds.height
        var image = source
        let vertical = safe(settings.vertical,-200,200)/500, horizontal = safe(settings.horizontal,-200,200)/500
        if vertical != 0 || horizontal != 0 {
            image = image.applyingFilter("CIPerspectiveTransform",parameters:[
                "inputTopLeft":CIVector(x:w*vertical,y:h-h*horizontal),
                "inputTopRight":CIVector(x:w-w*vertical,y:h+h*horizontal),
                "inputBottomLeft":CIVector(x:-w*vertical,y:h*horizontal),
                "inputBottomRight":CIVector(x:w+w*vertical,y:-h*horizontal)])
        }
        let angle = safe(settings.angle,-135,135)*Double.pi/180
        let scale = safe(settings.scale,1,600)/100
        let aspect = pow(2,safe(settings.aspect,-200,200)/100)
        let matrix = CGAffineTransform(translationX:-w/2,y:-h/2)
            .concatenating(CGAffineTransform(scaleX:scale*aspect,y:scale))
            .concatenating(CGAffineTransform(rotationAngle:-angle))
            .concatenating(CGAffineTransform(translationX:w/2+w*safe(settings.offsetX,-200,200)/100,y:h/2-h*safe(settings.offsetY,-200,200)/100))
        return image.transformed(by:matrix).composited(over:CIImage(color:.clear).cropped(to:bounds)).cropped(to:bounds)
    }

    private func autoCropRegion(source: CIImage, edits: EditState) throws -> CropRegion {
        guard edits.geometry.autoCrop else {return .full}
        let settings=edits.geometry
        geometryLock.lock();let cached=geometryCache;geometryLock.unlock()
        if let c=cached,c.source === source,c.settings==settings,c.turns==edits.quarterTurns,c.flip==edits.flipHorizontal,c.distortion==edits.adjustments.distortion {return c.region}
        var image=normalized(source)
        if edits.adjustments.distortion != 0 {
            let bounds=image.extent
            image=image.clampedToExtent().applyingFilter("CIBumpDistortion",parameters:[kCIInputCenterKey:CIVector(x:bounds.midX,y:bounds.midY),kCIInputRadiusKey:hypot(bounds.width,bounds.height)*0.65,kCIInputScaleKey:safe(edits.adjustments.distortion,-300,300)/250]).cropped(to:bounds)
        }
        let turns=((edits.quarterTurns%4)+4)%4
        if turns != 0 {image=normalized(image.transformed(by:CGAffineTransform(rotationAngle:-CGFloat(turns) * .pi / 2)))}
        if edits.flipHorizontal {image=normalized(image.transformed(by:CGAffineTransform(scaleX:-1,y:1)))}
        image=geometry(image,settings:settings)
        let region=try GeometryAutoCrop.region(in:image,context:context)
        geometryLock.lock();geometryCache=(source,settings,edits.quarterTurns,edits.flipHorizontal,edits.adjustments.distortion,region);geometryLock.unlock()
        return region
    }

    private func vignette(_ image: CIImage, adjustments a: Adjustments) -> CIImage {
        guard a.vignette != 0 else { return image }
        let bounds = image.extent
        var mask = LocalMask(name:"",kind:.radial)
        let radius = 0.15+safe(a.vignetteMidpoint, 0, 300)/100*0.55
        let round = safe(a.vignetteRoundness, -300, 300)/100
        let ratio = Double(min(bounds.width,bounds.height))
        let rx = max(0.005,radius*(1-max(0,round)*(1-ratio/Double(bounds.width))))
        let ry = max(0.005,radius*(1-max(0,round)*(1-ratio/Double(bounds.height))) * (1+min(0,round)*0.5))
        mask.start = UnitPoint2D(x:0.5-rx,y:0.5-ry); mask.end = UnitPoint2D(x:0.5+rx,y:0.5+ry)
        mask.feather = max(0.01,safe(a.vignetteFeather, 0, 300)/100); mask.inverted = true
        // Vignette keeps its existing edge-feather response; the new center-to-edge
        // profile is specific to local gradient selections.
        let selection = scalarMask(primitiveMask(mask, size: bounds.size, source: nil, centeredGradient: false), factor: -1, bias: 1)
        let darkened = image.applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:-safe(a.vignette, -300, 300)/50])
        return darkened.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:image,kCIInputMaskImageKey:selection]).cropped(to:bounds)
    }

    func export(source: CIImage, edits: EditState, options: ExportOptions, metadata: [String:Any] = [:], maxDimension: CGFloat? = nil) throws -> Data {
        var image = try processed(source:source,edits:edits,maxDimension:maxDimension)
        if options.longEdge > 0 {
            let factor = CGFloat(options.longEdge)/max(image.extent.width,image.extent.height)
            if factor < 1 || !options.dontEnlarge {
                image = normalized(image.applyingFilter("CILanczosScaleTransform",parameters:[kCIInputScaleKey:factor,kCIInputAspectRatioKey:1]))
                image = image.cropped(to:CGRect(x:0,y:0,width:max(1,floor(image.extent.width)),height:max(1,floor(image.extent.height))))
            }
        }
        if options.outputSharpening > 0 { image = image.clampedToExtent().applyingFilter("CIUnsharpMask",parameters:[kCIInputRadiusKey:0.7,kCIInputIntensityKey:safe(options.outputSharpening,0,100)/100]).cropped(to:image.extent) }
        if !options.watermark.isEmpty, let mark = watermark(options.watermark,size:image.extent.size) {
            image = mark.composited(over:image)
        }
        if options.format == .jpeg {
            image = image.composited(over:CIImage(color:.white).cropped(to:image.extent))
        }
        let targetSpace: CGColorSpace
        switch options.colorSpace {
        case .sRGB: targetSpace = colorSpace
        case .displayP3: targetSpace = CGColorSpace(name:CGColorSpace.displayP3)!
        case .adobeRGB: targetSpace = CGColorSpace(name:CGColorSpace.adobeRGB1998)!
        }
        let format: CIFormat = options.format != .jpeg && options.bitDepth == 16 ? .RGBA16 : .RGBA8
        guard let raster = context.createCGImage(image,from:image.extent,format:format,colorSpace:targetSpace) else { throw PipelineError.renderFailed }
        var properties: [CFString:Any] = [:]
        if options.includeMetadata {
            for (key,value) in ExportMetadata.filtered(metadata, removeGPS: options.removeGPS) where key != kCGImagePropertyOrientation as String { properties[key as CFString] = value }
        }
        properties[kCGImagePropertyOrientation] = 1
        properties[kCGImagePropertyPixelWidth] = raster.width; properties[kCGImagePropertyPixelHeight] = raster.height
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [String:Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1; properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        let type: String
        switch options.format {
        case .jpeg: type = UTType.jpeg.identifier; properties[kCGImageDestinationLossyCompressionQuality] = safe(options.quality,0,1)
        case .png: type = UTType.png.identifier
        case .tiff: type = UTType.tiff.identifier
        }
        return try encoded(raster,type:type,properties:properties)
    }

    private func watermark(_ text: String, size: CGSize) -> CIImage? {
        let w = max(1,Int(size.width)), h = max(1,Int(size.height))
        guard let cg = CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:colorSpace,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let fontSize = max(12,min(size.width,size.height)*0.027)
        let font = CTFontCreateWithName("Helvetica" as CFString,fontSize,nil)
        let attributed = NSAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:1,alpha:0.82)])
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(line,nil,nil,nil))
        cg.setShadow(offset:CGSize(width:0,height:-1),blur:3,color:CGColor(gray:0,alpha:0.7))
        cg.textPosition = CGPoint(x:max(10,size.width-width-fontSize),y:fontSize)
        CTLineDraw(line,cg)
        guard let image = cg.makeImage() else { return nil }
        return CIImage(cgImage:image)
    }

    private func normalized(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    private func cropRect(_ crop: CropRegion, in size: CGSize) -> CGRect {
        let x = safe(crop.x, 0, 1), y = safe(crop.y, 0, 1)
        let left = min(Int(size.width) - 1, max(0, Int((x * size.width).rounded())))
        let top = min(Int(size.height) - 1, max(0, Int((y * size.height).rounded())))
        let width = max(1, min(Int(size.width) - left, Int((safe(crop.width, 0, 1) * size.width).rounded())))
        let height = max(1, min(Int(size.height) - top, Int((safe(crop.height, 0, 1) * size.height).rounded())))
        return CGRect(x: left, y: Int(size.height) - top - height, width: width, height: height)
    }

    private func encoded(_ image: CGImage, type: String, properties: [CFString: Any]) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { throw PipelineError.exportFailed }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PipelineError.exportFailed }
        return data as Data
    }

    private func safe(_ value: Double, _ low: Double, _ high: Double) -> Double { value.isFinite ? min(high, max(low, value)) : low }
    private func smooth(_ value: Double) -> Double { let t = safe(value, 0, 1); return t * t * (3 - 2 * t) }
}
