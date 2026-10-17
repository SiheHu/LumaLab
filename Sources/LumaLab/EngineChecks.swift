import LumaDomain
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Run with the application's --self-test flag. Exercises real image operations.
enum EngineChecks {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { "Engine check failed: \(message)" }
    }

    static func run() throws -> String {
        let engine = ImagePipeline()
        var assertions = 0
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if condition() { assertions += 1 } else { failures.append(message) }
        }
        let width = 80, height = 60
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                rgba[i] = 64; rgba[i + 1] = 96; rgba[i + 2] = 128
            }
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        let fixture = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                              space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let source = CIImage(cgImage: fixture)
        let neutral = try engine.render(source: source, edits: EditState())
        let neutralPixels = pixels(neutral)
        try check(neutral.width == width && neutral.height == height, "neutral dimensions")
        try check(abs(Int(neutralPixels[0]) - 64) <= 2 && abs(Int(neutralPixels[1]) - 96) <= 2 && abs(Int(neutralPixels[2]) - 128) <= 2,
                  "neutral pixel fidelity")
        var edits = EditState()
        edits.adjustments.exposure = 1
        let bright = try engine.render(source: source, edits: edits)
        try check(Int(pixels(bright)[0]) > Int(neutralPixels[0]) + 15, "positive exposure raises pixel values")
        var mask = LocalMask(name: "Left", kind: .rectangle)
        mask.start = UnitPoint2D(x: 0, y: 0); mask.end = UnitPoint2D(x: 0.5, y: 1)
        mask.feather = 0.75; mask.adjustments.exposure = 1
        edits = EditState(); edits.masks = [mask]
        let masked = pixels(try engine.render(source: source, edits: edits))
        let left = (30 * width + 19) * 4, right = (30 * width + 68) * 4
        try check(Int(masked[left]) > Int(neutralPixels[left]) + 15, "mask applies inside rectangle")
        try check(abs(Int(masked[right]) - Int(neutralPixels[right])) <= 2, "mask preserves outside rectangle")
        edits.masks[0].inverted = true
        let inverted = pixels(try engine.render(source: source, edits: edits))
        try check(abs(Int(inverted[left]) - Int(neutralPixels[left])) <= 2 && Int(inverted[right]) > Int(neutralPixels[right]) + 15,
                  "inversion exchanges selected and unselected regions")
        edits.masks[0].inverted = false; edits.masks[0].opacity = 0.5
        let half = pixels(try engine.render(source: source, edits: edits))
        try check(half[left] > neutralPixels[left] && half[left] < masked[left], "opacity interpolates effect")
        edits.masks[0].opacity = 0
        let zero = pixels(try engine.render(source: source, edits: edits))
        try check(zero == neutralPixels, "zero-opacity mask is a no-op")
        edits = EditState(); edits.crop = CropRegion(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let cropped = try engine.render(source: source, edits: edits)
        try check(cropped.width == 40 && cropped.height == 30, "crop dimensions")
        edits.quarterTurns = 1
        let rotated = try engine.render(source: source, edits: edits)
        try check(rotated.width == 30 && rotated.height == 40, "crop uses rotated coordinate space")
        edits.crop = CropRegion(x: .nan, y: .infinity, width: -2, height: 0)
        let safeCrop = try engine.render(source: source, edits: edits)
        try check(safeCrop.width == 1 && safeCrop.height == 1, "invalid crop values remain renderable")
        edits = EditState()
        let preview = try engine.render(source: source, edits: edits, maxDimension: 40)
        try check(preview.width == 40 && preview.height == 30, "preview size")
        let png = try engine.exportPNG(source: source, edits: edits)
        let jpeg = try engine.exportJPEG(source: source, edits: edits)
        let loadedPNG = try engine.load(data: png), loadedJPEG = try engine.load(data: jpeg)
        try check(loadedPNG.extent.width == 80 && loadedPNG.extent.height == 60, "PNG export and decode")
        try check(loadedJPEG.extent.width == 80 && loadedJPEG.extent.height == 60, "JPEG export and decode")
        edits.masks = [mask]
        edits.crop = CropRegion(x: 0.1, y: 0.2, width: 0.6, height: 0.7)
        edits.quarterTurns = 3; edits.flipHorizontal = true
        edits.adjustments.temperature = 24
        let project = PhotoProject(sourceName: "Fixture.png", sourceData: png, edits: edits)
        let roundTrip = try JSONDecoder().decode(PhotoProject.self, from: JSONEncoder().encode(project))
        try check(roundTrip.sourceData == png && roundTrip.edits == edits && roundTrip.formatVersion == 2, "project Codable round trip")
        let hist = engine.histogram(neutral)
        try check(hist.count == 3 && hist.allSatisfy { $0.count == 256 && ($0.max() ?? 0) > 0 }, "RGB histogram bins")
        edits = EditState()
        // All supported mask kinds must produce continuous selections and valid compositing.
        for kind in MaskKind.manualKinds {
            var test = LocalMask(name: kind.title, kind: kind)
            test.adjustments.exposure = 1
            test.strokes = [[UnitPoint2D(x: 0.1, y: 0.5), UnitPoint2D(x: 0.9, y: 0.5)]]
            test.brushSize = 0.2; test.feather = 0.3
            edits.masks = [test]
            let result = pixels(try engine.render(source: source, edits: edits))
            try check(result != neutralPixels, "\(kind.title) affects pixels")
        }
        // Signed controls are tested on a colored ramp with texture and hard edges,
        // rather than a flat image where sharpness/clarity cannot have an effect.
        let texturedSource = CIImage(cgImage: controlFixture())
        let controlNeutral = pixels(try engine.render(source: texturedSource, edits: EditState()))
        let controls: [(String, WritableKeyPath<Adjustments, Double>, Bool)] = [
            ("Exposure", \.exposure, true), ("Contrast", \.contrast, true),
            ("Highlights", \.highlights, true), ("Shadows", \.shadows, true),
            ("Whites", \.whites, true), ("Blacks", \.blacks, true),
            ("Temperature", \.temperature, true), ("Tint", \.tint, true),
            ("Vibrance", \.vibrance, true), ("Saturation", \.saturation, true),
            ("Clarity", \.clarity, true), ("Sharpness", \.sharpness, false), ("Vignette", \.vignette, false)
        ]
        for (name, key, signed) in controls {
            for sign in (signed ? [-1.0, 1.0] : [1.0]) {
                var controlEdits = EditState()
                controlEdits.adjustments[keyPath: key] = sign * (name == "Exposure" ? 1 : 60)
                let changed = pixels(try engine.render(source: texturedSource, edits: controlEdits))
                let difference = zip(changed, controlNeutral).enumerated().reduce(0.0) { sum, item in
                    item.offset % 4 == 3 ? sum : sum + Double(abs(Int(item.element.0) - Int(item.element.1)))
                } / Double(160 * 120 * 3)
                try check(difference > 0.02, "\(name) \(sign > 0 ? "+" : "−") changes textured pixels")
                if ["Exposure", "Highlights", "Shadows", "Whites", "Blacks"].contains(name) {
                    let range = name == "Shadows" || name == "Blacks" ? 0..<40 : (name == "Highlights" || name == "Whites" ? 110..<160 : 0..<160)
                    let delta = mean(changed, width: 160, x: range) - mean(controlNeutral, width: 160, x: range)
                    try check(delta * sign > 0.2, "\(name) has the expected brightness direction")
                }
                if name == "Temperature" {
                    let warmth = mean(changed, width: 160, x: 0..<160, channel: 0) - mean(changed, width: 160, x: 0..<160, channel: 2)
                    let originalWarmth = mean(controlNeutral, width: 160, x: 0..<160, channel: 0) - mean(controlNeutral, width: 160, x: 0..<160, channel: 2)
                    try check((warmth - originalWarmth) * sign > 1, "Temperature positive warms / negative cools")
                }
            }
        }
        // Validate sparse brush events form a connected stroke at its midpoint.
        var brush = LocalMask(name: "Continuous", kind: .brush)
        brush.strokes = [[UnitPoint2D(x: 0.1, y: 0.2), UnitPoint2D(x: 0.9, y: 0.2)]]
        brush.brushSize = 0.2; brush.feather = 0; brush.adjustments.exposure = 1
        edits = EditState(); edits.masks = [brush]
        let stroke = pixels(try engine.render(source: source, edits: edits))
        try check(stroke[(12 * width + 40) * 4] > neutralPixels[(12 * width + 40) * 4] + 15,
                  "brush connects sparse events in top-left coordinates")
        try check(abs(Int(stroke[(48 * width + 40) * 4]) - Int(neutralPixels[(48 * width + 40) * 4])) <= 2,
                  "brush preserves opposite side")
        // Fractional preview sizes must not leave an unmasked fringe.
        let fractional = CGSize(width: 37, height: 27.75)
        let selection = engine.maskImage(mask, size: fractional)
        // Core Image rounds finite extents outward to whole pixels.
        try check(selection.extent.width >= fractional.width && selection.extent.width <= ceil(fractional.width) &&
                  selection.extent.height >= fractional.height && selection.extent.height <= ceil(fractional.height),
                  "mask covers fractional preview extent without a missing fringe")
        edits.masks = [mask]
        let small = try engine.render(source: source, edits: edits, maxDimension: 37)
        let smallPixels = pixels(small)
        let sx = small.width / 4, sy = small.height / 2
        let unselected = (sy * small.width + small.width - 6) * 4
        try check(Int(smallPixels[(sy * small.width + sx) * 4]) > Int(neutralPixels[left]) + 15 &&
                  abs(Int(smallPixels[unselected]) - Int(neutralPixels[right])) <= 2,
                  "preview and full export agree on normalized mask selection")
        // Decode a real EXIF orientation fixture, not an already-rotated CIImage.
        let orientedData = NSMutableData()
        let orientedDestination = CGImageDestinationCreateWithData(orientedData, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(orientedDestination, fixture, [kCGImagePropertyOrientation: 6] as CFDictionary)
        try check(CGImageDestinationFinalize(orientedDestination), "EXIF fixture encoding")
        let oriented = try engine.load(data: orientedData as Data)
        try check(oriented.extent == CGRect(x: 0, y: 0, width: 60, height: 80), "EXIF orientation applied and origin normalized")
        let transparent = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        let transparentPNG = try engine.load(data: engine.exportPNG(source: transparent, edits: EditState()))
        let pngPixels = pixels(try engine.render(source: transparentPNG, edits: EditState()))
        try check(pngPixels[3] == 0, "PNG preserves transparency")
        let mattedJPEG = try engine.load(data: engine.exportJPEG(source: transparent, edits: EditState()))
        let mattePixels = pixels(try engine.render(source: mattedJPEG, edits: EditState()))
        try check(mattePixels[0] >= 250 && mattePixels[1] >= 250 && mattePixels[2] >= 250 && mattePixels[3] == 255,
                  "JPEG flattens transparency on white")
        // New engine features are verified against independently generated color patches.
        let colorSource = CIImage(cgImage: colorFixture())
        let colorNeutral = pixels(try engine.render(source: colorSource, edits: EditState()))
        var upgrades: [(String, (inout EditState) -> Void)] = [
            ("Texture +", { $0.adjustments.texture = 75 }), ("Texture −", { $0.adjustments.texture = -75 }),
            ("Dehaze +", { $0.adjustments.dehaze = 60 }), ("Dehaze −", { $0.adjustments.dehaze = -60 }),
            ("Luminance denoise", { $0.adjustments.noiseReduction = 90 }),
            ("Color denoise", { $0.adjustments.colorNoiseReduction = 90 }),
            ("Grain", { $0.adjustments.grain = 70 }),
            ("Manual distortion +", { $0.adjustments.distortion = 60 }),
            ("Manual distortion −", { $0.adjustments.distortion = -60 }),
            ("Defringe", { $0.adjustments.defringe = 75 }),
            ("Master curve", { $0.curves.master[2].y = 0.65 }),
            ("Red curve", { $0.curves.red[2].y = 0.65 }),
            ("Green curve", { $0.curves.green[2].y = 0.65 }),
            ("Blue curve", { $0.curves.blue[2].y = 0.65 }),
            ("Parametric shadows", { $0.curves.shadows = 50 }),
            ("Parametric darks", { $0.curves.darks = 50 }),
            ("Parametric lights", { $0.curves.lights = 50 }),
            ("Parametric highlights", { $0.curves.highlights = 50 }),
            ("Point Color", { $0.pointColor.enabled = true; $0.pointColor.color = [0.9,0.1,0.1]; $0.pointColor.tolerance = 0.5; $0.pointColor.hue = 70 }),
            ("Shadow wheel", { $0.grading.shadows.hue = 20; $0.grading.shadows.saturation = 70 }),
            ("Midtone wheel", { $0.grading.midtones.hue = 100; $0.grading.midtones.saturation = 70 }),
            ("Highlight wheel", { $0.grading.highlights.hue = 260; $0.grading.highlights.saturation = 70 }),
            ("Calibration red hue", { $0.calibration.redHue = 60 }),
            ("Calibration red saturation", { $0.calibration.redSaturation = -60 }),
            ("Calibration green hue", { $0.calibration.greenHue = 60 }),
            ("Calibration green saturation", { $0.calibration.greenSaturation = -60 }),
            ("Calibration blue hue", { $0.calibration.blueHue = 60 }),
            ("Calibration blue saturation", { $0.calibration.blueSaturation = -60 }),
            ("Calibration shadow tint", { $0.calibration.shadowTint = 60 }),
            ("Fine angle", { $0.geometry.angle = 8 }), ("Vertical perspective", { $0.geometry.vertical = 30 }),
            ("Horizontal perspective", { $0.geometry.horizontal = 30 }), ("Aspect", { $0.geometry.aspect = 30 }),
            ("Scale", { $0.geometry.scale = 120 }), ("X offset", { $0.geometry.offsetX = 10 }),
            ("Y offset", { $0.geometry.offsetY = 10 })
        ]
        for band in 0..<8 {
            upgrades.append(("HSL band \(band) hue", { $0.hsl[band].hue = 60 }))
            upgrades.append(("HSL band \(band) saturation", { $0.hsl[band].saturation = -60 }))
            upgrades.append(("HSL band \(band) luminance", { $0.hsl[band].luminance = 60 }))
        }
        for (name, update) in upgrades {
            var state = EditState(); update(&state)
            let result = pixels(try engine.render(source: colorSource, edits: state))
            try check(result != colorNeutral, "\(name) affects rendered pixels")
        }
        let dependent: [(String, (inout EditState) -> Void, (inout EditState) -> Void)] = [
            ("Sharpen radius", { $0.adjustments.sharpness = 60 }, { $0.adjustments.sharpenRadius = 3 }),
            ("Sharpen detail", { $0.adjustments.sharpness = 60 }, { $0.adjustments.sharpenDetail = 90 }),
            ("Sharpen edge masking", { $0.adjustments.sharpness = 60 }, { $0.adjustments.sharpenMasking = 90 }),
            ("Grain size", { $0.adjustments.grain = 70 }, { $0.adjustments.grainSize = 75 }),
            ("Grain roughness", { $0.adjustments.grain = 70 }, { $0.adjustments.grainRoughness = 90 }),
            ("Vignette midpoint", { $0.adjustments.vignette = 60 }, { $0.adjustments.vignetteMidpoint = 10 }),
            ("Vignette feather", { $0.adjustments.vignette = 60 }, { $0.adjustments.vignetteFeather = 15 }),
            ("Vignette roundness", { $0.adjustments.vignette = 60 }, { $0.adjustments.vignetteRoundness = 90 }),
            ("Grading blending", { $0.grading.shadows.saturation = 70; $0.grading.shadows.hue = 20 }, { $0.grading.blending = 100 }),
            ("Grading balance", { $0.grading.shadows.saturation = 70; $0.grading.shadows.hue = 20 }, { $0.grading.balance = 80 }),
            ("Point Color tolerance", { $0.pointColor.enabled = true; $0.pointColor.hue = 60; $0.pointColor.color = [0.9,0.1,0.1] }, { $0.pointColor.tolerance = 0.7 })
        ]
        for (name, setup, update) in dependent {
            var state = EditState(); setup(&state)
            let before = pixels(try engine.render(source: colorSource, edits: state)); update(&state)
            let after = pixels(try engine.render(source: colorSource, edits: state))
            try check(before != after, "\(name) changes its active effect")
        }
        for sign in [-1.0,1.0] {
            var state = EditState(); state.adjustments.tint = sign*60
            let tinted = pixels(try engine.render(source: colorSource, edits: state))
            func magenta(_ p: [UInt8]) -> Double { (mean(p,width:160,x:0..<160,channel:0)+mean(p,width:160,x:0..<160,channel:2))/2-mean(p,width:160,x:0..<160,channel:1) }
            try check((magenta(tinted)-magenta(colorNeutral))*sign > 1,"Tint positive is magenta / negative green")
        }
        var gentle = EditState(); gentle.adjustments.contrast = 100
        let lowContrast = pixels(try engine.render(source:texturedSource,edits:gentle))
        let maxContrastDelta = zip(lowContrast,controlNeutral).map { abs(Int($0)-Int($1)) }.max() ?? 0
        let previousContrast = pixels(try engine.render(source:texturedSource.applyingFilter("CIColorControls",parameters:[kCIInputContrastKey:1.01,kCIInputSaturationKey:1]),edits:EditState()))
        let previousDelta = zip(previousContrast,controlNeutral).map { abs(Int($0)-Int($1)) }.max() ?? 0
        try check(maxContrastDelta > previousDelta,"Contrast produces a larger response than the previous release (new: \(maxContrastDelta), previous: \(previousDelta))")
        let expectedContrast = pixels(try engine.render(source:texturedSource.applyingFilter("CIColorControls",parameters:[kCIInputContrastKey:1.03,kCIInputSaturationKey:1]),edits:EditState()))
        try check(lowContrast == expectedContrast,"Contrast at +100 matches a 1.03 multiplier")
        var nonBuildup = LocalMask(name:"Union",kind:.brush)
        nonBuildup.strokes = [[UnitPoint2D(x:0.2,y:0.5),UnitPoint2D(x:0.8,y:0.5)]]
        nonBuildup.brushSize = 0.4; nonBuildup.feather = 0.75; nonBuildup.flow = 0.6; nonBuildup.density = 0.7
        nonBuildup.adjustments.exposure = 2
        edits = EditState(); edits.masks = [nonBuildup]
        let once = pixels(try engine.render(source:source,edits:edits))
        edits.masks[0].strokes.append(nonBuildup.strokes[0]); edits.masks[0].strokes.append(nonBuildup.strokes[0])
        let repeated = pixels(try engine.render(source:source,edits:edits))
        try check(repeated == once,"Repeated brush strokes do not build up intensity")
        edits.masks[0].erasedStrokes = [[UnitPoint2D(x:0.5,y:0.2),UnitPoint2D(x:0.5,y:0.8)]]
        let erased = pixels(try engine.render(source:source,edits:edits))
        try check(erased[(30*80+40)*4] < once[(30*80+40)*4],"Eraser subtracts coverage")
        var combined = LocalMask(name:"Compound",kind:.rectangle)
        combined.start = UnitPoint2D(x:0,y:0); combined.end = UnitPoint2D(x:0.6,y:1); combined.feather = 0
        var component = MaskComponent(); component.kind = .rectangle; component.start = UnitPoint2D(x:0.4,y:0); component.end = UnitPoint2D(x:1,y:1); component.feather = 0
        combined.components = [component]
        func selected(_ mask: LocalMask) throws -> [UInt8] { pixels(try engine.render(source:engine.maskImage(mask,size:CGSize(width:80,height:60),source:source),edits:EditState())) }
        let maskContext = CIContext(options: [.workingColorSpace: NSNull()])
        func coverage(_ mask: LocalMask, size: CGSize = CGSize(width:80,height:60)) -> [Float] {
            let w = Int(size.width), h = Int(size.height)
            var values = [Float](repeating: 0, count: w*h*4)
            values.withUnsafeMutableBytes { storage in
                maskContext.render(engine.maskImage(mask,size:size,source:source), toBitmap: storage.baseAddress!,
                                   rowBytes: w*16, bounds: CGRect(origin:.zero,size:size), format:.RGBAf, colorSpace:nil)
            }
            return stride(from:0,to:values.count,by:4).map { values[$0] }
        }
        var base = combined; base.components = []
        var operand = LocalMask(name:"Operand",kind:.rectangle)
        operand.start = component.start; operand.end = component.end; operand.feather = component.feather
        let a = coverage(base), b = coverage(operand)
        let union = coverage(combined)
        try check(union.indices.allSatisfy { abs(union[$0]-max(a[$0],b[$0])) < 0.004 },"Compound add uses maximum coverage across a gradient")
        combined.components[0].operation = .subtract
        let subtracted = coverage(combined)
        try check(subtracted.indices.allSatisfy { abs(subtracted[$0]-max(0,a[$0]-b[$0])) < 0.004 },"Compound subtract removes gradient overlap")
        combined.components[0].operation = .intersect
        let intersection = coverage(combined)
        try check(intersection.indices.allSatisfy { abs(intersection[$0]-min(a[$0],b[$0])) < 0.004 },"Compound intersect keeps minimum gradient coverage")
        var radial = LocalMask(name:"Soft",kind:.radial); radial.start = UnitPoint2D(x:0.1,y:0.1);radial.end = UnitPoint2D(x:0.9,y:0.9)
        let gradientPixels = try selected(radial)
        let levels = Set((8..<40).map { gradientPixels[(30*80+$0)*4] })
        try check(levels.count > 12,"Radial mask has a smooth feather gradient")
        radial.kind = .rectangle
        let rectanglePixels = try selected(radial)
        let rectangleLevels = Set((8..<40).map { rectanglePixels[(30*80+$0)*4] })
        try check(rectangleLevels.count > 12,"Rectangle mask has a smooth feather gradient")
        // Odd dimensions put samples exactly at the center, quarter radii and boundary.
        for kind in [MaskKind.radial, .rectangle] {
            var gradient = LocalMask(name:"Profile",kind:kind)
            gradient.start = UnitPoint2D(x:0.5/201,y:0.5/201)
            gradient.end = UnitPoint2D(x:200.5/201,y:200.5/201)
            let values = coverage(gradient,size:CGSize(width:201,height:201))
            func level(_ x: Int, _ y: Int = 100) -> Float { values[y*201+x] }
            try check(abs(level(100)-1) < 0.006 && abs(level(200)) < 0.006,"\(kind.title) center reaches full coverage, boundary reaches zero")
            try check(abs(level(125)-0.75) < 0.006 && abs(level(150)-0.5) < 0.006 && abs(level(175)-0.25) < 0.006,"\(kind.title) quarter-radius samples fall linearly throughout the selection")
            try check((100..<200).allSatisfy { level($0) > level($0+1) },"\(kind.title) has no flat interior plateau")
            let flat = CIImage(color:CIColor(red:0.2,green:0.2,blue:0.2)).cropped(to:CGRect(x:0,y:0,width:201,height:201))
            var gradientEdit = EditState(); gradient.adjustments.exposure = 2; gradientEdit.masks = [gradient]
            let graded = pixels(try engine.render(source:flat,edits:gradientEdit))
            var referenceEdit = EditState(); referenceEdit.adjustments.exposure = 1
            let oneStop = pixels(try engine.render(source:flat,edits:referenceEdit))
            try check(abs(Int(graded[(100*201+150)*4])-Int(oneStop[0])) <= 1,"\(kind.title) half coverage at +2 EV applies +1 EV rather than mixing a clipped foreground")
            for softness in [0.0,1.0] {
                gradient.feather = softness
                let curved = coverage(gradient,size:CGSize(width:201,height:201))
                try check(curved[100*201+125] > curved[100*201+150] && curved[100*201+150] > curved[100*201+175],"\(kind.title) softness reshapes the entire gradient without a plateau")
            }
            if kind == .rectangle {
                // A nearest-edge formula has a cusp on x == y. Check its absence.
                let acrossDiagonal = [-2,-1,0,1,2].map { level(150+$0,150-$0) }
                let steps = zip(acrossDiagonal.dropFirst(),acrossDiagonal).map { $0-$1 }
                try check((steps.max() ?? 0)-(steps.min() ?? 0) < 0.009,"Rectangle gradient has no diagonal starburst crease")
                try check(abs(level(150,150)-0.25) < 0.006 && abs(level(200,150)) < 0.006,"Rectangle corners use continuous separable coverage")
            }
        }
        let output = try engine.outputSize(source:source,edits:edits)
        let reference = try engine.render(source:source,edits:edits)
        try check(output == CGSize(width:reference.width,height:reference.height),"Viewport dimensions match full-resolution output")
        let fitted = ViewportGeometry.fitScale(image:CGSize(width:3000,height:2000),viewport:CGSize(width:954,height:654))
        try check(abs(fitted-0.3) < 0.00001,"Viewport fit accounts for padding and image aspect")
        try check(ViewportGeometry.fitScale(image:CGSize(width:0,height:0),viewport:.zero).isFinite,"Viewport handles temporary zero-size layout")
        let overlay1 = pixels(try engine.selectionOverlay(nonBuildup,source:source,maxDimension:80))
        let overlay2 = pixels(try engine.selectionOverlay(nonBuildup,source:source,maxDimension:80))
        try check(overlay1 == overlay2 && (stride(from:3,to:overlay1.count,by:4).map { overlay1[$0] }.max() ?? 0) > 0,"Selection overlay is deterministic alpha coverage")
        var range = LocalMask(name:"Color",kind:.colorRange); range.rangeColor = [0.9,0.1,0.1];range.rangeTolerance = 0.18
        let rangePixels = pixels(try engine.render(source:engine.maskImage(range,size:colorSource.extent.size,source:colorSource),edits:EditState()))
        try check(rangePixels[(60*160+10)*4] > rangePixels[(60*160+110)*4] + 20,"Color Range follows original source colors")
        range.kind = .luminanceRange; range.luminanceLow = 0.65;range.luminanceHigh = 1
        let luminancePixels = pixels(try engine.render(source:engine.maskImage(range,size:colorSource.extent.size,source:colorSource),edits:EditState()))
        try check(luminancePixels != rangePixels,"Luminance Range uses independent luminance selection")
        for depth in [8,16] {
            var options = ExportOptions(); options.format = .tiff;options.bitDepth = depth;options.colorSpace = .adobeRGB
            let data = try engine.export(source:colorSource,edits:EditState(),options:options)
            let src = CGImageSourceCreateWithData(data as CFData,nil)!
            let bitmap = CGImageSourceCreateImageAtIndex(src,0,nil)!
            try check(bitmap.bitsPerComponent == depth,"TIFF exports actual \(depth)-bit channels")
        }
        var options = ExportOptions();options.format = .png;options.longEdge = 40;options.colorSpace = .displayP3
        let resizedData = try engine.export(source:colorSource,edits:EditState(),options:options,metadata:[kCGImagePropertyTIFFDictionary as String:[kCGImagePropertyTIFFArtist as String:"LumaLab test"],kCGImagePropertyOrientation as String:6])
        let resizedSource = CGImageSourceCreateWithData(resizedData as CFData,nil)!
        let resized = CGImageSourceCreateImageAtIndex(resizedSource,0,nil)!
        try check(resized.width == 40 && resized.height == 30,"Export long-edge resize")
        try check(resized.colorSpace?.name == CGColorSpace.displayP3,"Export embeds Display P3 profile")
        options.format = .tiff;options.longEdge = 0
        let metadataData = try engine.export(source:colorSource,edits:EditState(),options:options,metadata:[kCGImagePropertyTIFFDictionary as String:[kCGImagePropertyTIFFArtist as String:"LumaLab test"],kCGImagePropertyOrientation as String:6])
        let metadataSource = CGImageSourceCreateWithData(metadataData as CFData,nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(metadataSource,0,nil)! as NSDictionary
        let tiffProperties = properties[kCGImagePropertyTIFFDictionary] as? NSDictionary
        try check(tiffProperties?[kCGImagePropertyTIFFArtist] as? String == "LumaLab test","Export preserves non-orientation metadata")
        try check((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 == 1,"Export resets orientation metadata")
        options.format = .png;options.longEdge = 40
        let plain = try engine.export(source:colorSource,edits:EditState(),options:options)
        options.outputSharpening = 60
        let outputSharpened = try engine.export(source:colorSource,edits:EditState(),options:options)
        try check(outputSharpened != plain,"Output sharpening affects export pixels")
        options.watermark = "LumaLab"
        let marked = try engine.export(source:colorSource,edits:EditState(),options:options)
        try check(marked != plain,"Watermark and output sharpening affect export")
        if !failures.isEmpty { throw Failure(message: failures.joined(separator: "\n")) }
        return "PASS — \(assertions) image engine checks (all controls, color tools, mask math/coverage, geometry, EXIF, 8/16-bit export, ICC/metadata, alpha and project round trip)."
    }


    private static func colorFixture() -> CGImage {
        let width = 160, height = 120
        let hues = [0.0,1.0/12,1.0/6,1.0/3,0.5,2.0/3,0.75,5.0/6]
        var bytes = [UInt8](repeating:255,count:width*height*4)
        for y in 0..<height { for x in 0..<width {
            let light = 0.15+Double(y)/Double(height-1)*0.7
            let rgb = EngineColor.rgb(hues[x/20],0.8,light)
            let noise = (x+y)%2 == 0 ? 0.012 : -0.012
            let i = (y*width+x)*4
            bytes[i] = UInt8(EngineColor.clamp(rgb.0+noise)*255)
            bytes[i+1] = UInt8(EngineColor.clamp(rgb.1-noise)*255)
            bytes[i+2] = UInt8(EngineColor.clamp(rgb.2+noise)*255)
        } }
        return CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:CGDataProvider(data:Data(bytes) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
    }

    private static func controlFixture() -> CGImage {
        let width = 160, height = 120
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let level = 40 + x * 170 / (width - 1)
                bytes[offset] = UInt8(level)
                bytes[offset + 1] = UInt8(level + 10)
                bytes[offset + 2] = UInt8(level - 10)
                if y > height / 2 && x % 12 < 6 { bytes[offset] = UInt8(min(255, level + 30)) }
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private static func mean(_ bytes: [UInt8], width: Int, x: Range<Int>, channel: Int? = nil) -> Double {
        let height = bytes.count / (width * 4)
        var sum = 0.0
        for y in 0..<height {
            for column in x {
                let offset = (y * width + column) * 4
                if let c = channel { sum += Double(bytes[offset + c]) }
                else { sum += (Double(bytes[offset]) + Double(bytes[offset + 1]) + Double(bytes[offset + 2])) / 3 }
            }
        }
        return sum / Double(height * x.count)
    }

    private static func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { storage in
            let cg = CGContext(data: storage.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                               bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            cg.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
}
