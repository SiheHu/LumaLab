import Foundation

package struct Adjustments: Codable, Equatable {
    package var exposure: Double = 0
    package var contrast: Double = 0
    package var highlights: Double = 0
    package var shadows: Double = 0
    package var whites: Double = 0
    package var blacks: Double = 0
    package var temperature: Double = 0
    package var tint: Double = 0
    package var vibrance: Double = 0
    package var saturation: Double = 0
    package var clarity: Double = 0
    package var sharpness: Double = 0
    package var vignette: Double = 0
    package var texture: Double = 0
    package var dehaze: Double = 0
    package var noiseReduction: Double = 0
    package var colorNoiseReduction: Double = 0
    package var sharpenRadius: Double = 1
    package var sharpenDetail: Double = 25
    package var sharpenMasking: Double = 0
    package var grain: Double = 0
    package var grainSize: Double = 25
    package var grainRoughness: Double = 50
    package var vignetteMidpoint: Double = 50
    package var vignetteFeather: Double = 75
    package var vignetteRoundness: Double = 0
    package var distortion: Double = 0
    package var defringe: Double = 0
    package static let neutral = Adjustments()

    package init(exposure: Double = 0, contrast: Double = 0, highlights: Double = 0, shadows: Double = 0, whites: Double = 0, blacks: Double = 0, temperature: Double = 0, tint: Double = 0, vibrance: Double = 0, saturation: Double = 0, clarity: Double = 0, sharpness: Double = 0, vignette: Double = 0, texture: Double = 0, dehaze: Double = 0, noiseReduction: Double = 0, colorNoiseReduction: Double = 0, sharpenRadius: Double = 1, sharpenDetail: Double = 25, sharpenMasking: Double = 0, grain: Double = 0, grainSize: Double = 25, grainRoughness: Double = 50, vignetteMidpoint: Double = 50, vignetteFeather: Double = 75, vignetteRoundness: Double = 0, distortion: Double = 0, defringe: Double = 0) {
        self.exposure = exposure; self.contrast = contrast; self.highlights = highlights; self.shadows = shadows; self.whites = whites; self.blacks = blacks; self.temperature = temperature; self.tint = tint; self.vibrance = vibrance; self.saturation = saturation; self.clarity = clarity; self.sharpness = sharpness; self.vignette = vignette; self.texture = texture; self.dehaze = dehaze; self.noiseReduction = noiseReduction; self.colorNoiseReduction = colorNoiseReduction; self.sharpenRadius = sharpenRadius; self.sharpenDetail = sharpenDetail; self.sharpenMasking = sharpenMasking; self.grain = grain; self.grainSize = grainSize; self.grainRoughness = grainRoughness; self.vignetteMidpoint = vignetteMidpoint; self.vignetteFeather = vignetteFeather; self.vignetteRoundness = vignetteRoundness; self.distortion = distortion; self.defringe = defringe
    }
}

package struct UnitPoint2D: Codable, Equatable {
    package var x: Double
    package var y: Double
    package static let center = UnitPoint2D(x: 0.5, y: 0.5)

    package init(x: Double, y: Double) {
        self.x = x; self.y = y
    }
}

package struct CropRegion: Codable, Equatable {
    package var x: Double = 0
    package var y: Double = 0
    package var width: Double = 1
    package var height: Double = 1
    package static let full = CropRegion()
    package var isFull: Bool { self == .full }

    package init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

package enum MaskKind: String, Codable, CaseIterable, Identifiable {
    case brush, linear, radial, rectangle, colorRange, luminanceRange, automatic
    package static var manualKinds: [MaskKind] { allCases.filter { $0 != .automatic } }
    package var id: String { rawValue }
    package var title: String {
        switch self {
        case .automatic: return "自动识别"
        case .brush: return "画笔"
        case .linear: return "线性渐变"
        case .radial: return "径向渐变"
        case .rectangle: return "矩形渐变"
        case .colorRange: return "颜色范围"
        case .luminanceRange: return "亮度范围"
        }
    }
    package var symbol: String {
        switch self {
        case .automatic: return "sparkles"
        case .brush: return "paintbrush.pointed"
        case .linear: return "line.diagonal"
        case .radial: return "circle.dashed"
        case .rectangle: return "rectangle.dashed"
        case .colorRange: return "eyedropper.halffull"
        case .luminanceRange: return "circle.lefthalf.filled"
        }
    }
}

package struct LocalMask: Codable, Equatable, Identifiable {
    package var id = UUID()
    package var name: String = "选区"
    package var kind: MaskKind = .brush
    package var enabled = true
    package var inverted = false
    package var overlayVisible = true
    package var handlesVisible = true
    package var overlayColor: [Double] = [1,0.12,0.10]
    package var groupID: UUID?
    package var groupName: String?
    package var automaticKind: AutomaticMaskKind?
    package var automaticIndex: Int?
    package var opacity: Double = 1
    package var feather: Double = 0.75
    package var brushSize: Double = 0.07
    package var brushVersion: Int? = 2
    package var raster: PortableMaskRaster? = nil
    package var edgeStrokes: [EdgeBrushStroke] = []
    package var start = UnitPoint2D(x: 0.3, y: 0.3)
    package var end = UnitPoint2D(x: 0.7, y: 0.7)
    package var strokes: [[UnitPoint2D]] = []
    package var erasedStrokes: [[UnitPoint2D]] = []
    package var flow: Double = 1
    package var density: Double = 1
    package var rangeColor: [Double] = [0.5, 0.5, 0.5]
    package var rangeTolerance: Double = 0.25
    package var luminanceLow: Double = 0.25
    package var luminanceHigh: Double = 0.75
    package var components: [MaskComponent] = []
    package var adjustments = Adjustments()
    package var hsl = HSLBand.defaults
    package var disabledSections: Set<AdjustmentSection> = []

    package init(id: UUID = UUID(), name: String = "选区", kind: MaskKind = .brush, enabled: Bool = true, inverted: Bool = false, opacity: Double = 1, feather: Double = 0.75, brushSize: Double = 0.07, start: UnitPoint2D = UnitPoint2D(x: 0.3, y: 0.3), end: UnitPoint2D = UnitPoint2D(x: 0.7, y: 0.7), strokes: [[UnitPoint2D]] = [], erasedStrokes: [[UnitPoint2D]] = [], flow: Double = 1, density: Double = 1, rangeColor: [Double] = [0.5, 0.5, 0.5], rangeTolerance: Double = 0.25, luminanceLow: Double = 0.25, luminanceHigh: Double = 0.75, components: [MaskComponent] = [], adjustments: Adjustments = Adjustments(), disabledSections: Set<AdjustmentSection> = []) {
        self.id = id; self.name = name; self.kind = kind; self.enabled = enabled; self.inverted = inverted; self.opacity = opacity; self.feather = feather; self.brushSize = brushSize; self.start = start; self.end = end; self.strokes = strokes; self.erasedStrokes = erasedStrokes; self.flow = flow; self.density = density; self.rangeColor = rangeColor; self.rangeTolerance = rangeTolerance; self.luminanceLow = luminanceLow; self.luminanceHigh = luminanceHigh; self.components = components; self.adjustments = adjustments; self.disabledSections = disabledSections
    }
}

package struct EditState: Codable, Equatable {
    package var adjustments = Adjustments()
    package var masks: [LocalMask] = []
    package var repairs: [RepairStroke] = []
    package var crop = CropRegion.full
    package var quarterTurns: Int = 0
    package var flipHorizontal = false
    package var geometry = GeometrySettings()
    package var curves = CurveSettings()
    package var hsl = HSLBand.defaults
    package var grading = ColorGrading()
    package var pointColor = PointColorSettings()
    package var calibration = CalibrationSettings()
    package var lut = LUTSettings()
    package var disabledSections: Set<AdjustmentSection> = []

    package init(adjustments: Adjustments = Adjustments(), masks: [LocalMask] = [], repairs: [RepairStroke] = [], crop: CropRegion = CropRegion.full, quarterTurns: Int = 0, flipHorizontal: Bool = false, geometry: GeometrySettings = GeometrySettings(), curves: CurveSettings = CurveSettings(), hsl: [HSLBand] = HSLBand.defaults, grading: ColorGrading = ColorGrading(), pointColor: PointColorSettings = PointColorSettings(), calibration: CalibrationSettings = CalibrationSettings(), disabledSections: Set<AdjustmentSection> = []) {
        self.adjustments = adjustments; self.masks = masks; self.repairs = repairs; self.crop = crop; self.quarterTurns = quarterTurns; self.flipHorizontal = flipHorizontal; self.geometry = geometry; self.curves = curves; self.hsl = hsl; self.grading = grading; self.pointColor = pointColor; self.calibration = calibration; self.disabledSections = disabledSections
    }
}

package struct PhotoProject: Codable {
    package var formatVersion: Int = 2
    package var sourceName: String
    package var sourceData: Data
    package var edits: EditState
    package var snapshots: [SavedSnapshot] = []
    package var virtualCopies: [SavedSnapshot] = []
    package var history: [EditState] = []

    package init(formatVersion: Int = 2, sourceName: String, sourceData: Data, edits: EditState, snapshots: [SavedSnapshot] = [], virtualCopies: [SavedSnapshot] = [], history: [EditState] = []) {
        self.formatVersion = formatVersion; self.sourceName = sourceName; self.sourceData = sourceData; self.edits = edits; self.snapshots = snapshots; self.virtualCopies = virtualCopies; self.history = history
    }
}

package enum EditorTool: String, CaseIterable {
    case edit, crop, masks, repair
    package var title: String {
        switch self { case .edit: return "调整"; case .crop: return "裁剪与几何"; case .masks: return "局部选区"; case .repair: return "污点修复" }
    }
    package var symbol: String {
        switch self {
        case .edit: return "slider.horizontal.3"
        case .crop: return "crop.rotate"
        case .repair: return "bandage"
        case .masks: return "circle.dashed.inset.filled"
        }
    }
}


package struct GeometrySettings: Codable, Equatable {
    package var angle: Double = 0
    package var vertical: Double = 0
    package var horizontal: Double = 0
    package var aspect: Double = 0
    package var scale: Double = 100
    package var offsetX: Double = 0
    package var offsetY: Double = 0
    package var autoCrop = false

    package init(angle: Double = 0, vertical: Double = 0, horizontal: Double = 0, aspect: Double = 0, scale: Double = 100, offsetX: Double = 0, offsetY: Double = 0, autoCrop: Bool = false) {
        self.angle = angle; self.vertical = vertical; self.horizontal = horizontal; self.aspect = aspect; self.scale = scale; self.offsetX = offsetX; self.offsetY = offsetY; self.autoCrop = autoCrop
    }
}
package struct CurveSettings: Codable, Equatable {
    package static let line: [UnitPoint2D] = [0.0, 0.5, 1.0].map { UnitPoint2D(x: $0, y: $0) }
    package var master = CurveSettings.line
    package var red = CurveSettings.line
    package var green = CurveSettings.line
    package var blue = CurveSettings.line
    package var shadows: Double = 0
    package var darks: Double = 0
    package var lights: Double = 0
    package var highlights: Double = 0

    package init(master: [UnitPoint2D] = CurveSettings.line, red: [UnitPoint2D] = CurveSettings.line, green: [UnitPoint2D] = CurveSettings.line, blue: [UnitPoint2D] = CurveSettings.line, shadows: Double = 0, darks: Double = 0, lights: Double = 0, highlights: Double = 0) {
        self.master = master; self.red = red; self.green = green; self.blue = blue; self.shadows = shadows; self.darks = darks; self.lights = lights; self.highlights = highlights
    }
}
package struct HSLBand: Codable, Equatable, Identifiable {
    package var name: String
    package var hue: Double = 0
    package var saturation: Double = 0
    package var luminance: Double = 0
    package var id: String { name }
    package static var defaults: [HSLBand] { ["红", "橙", "黄", "绿", "青", "蓝", "紫", "洋红"].map { HSLBand(name: $0) } }

    package init(name: String, hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
        self.name = name; self.hue = hue; self.saturation = saturation; self.luminance = luminance
    }
}
package struct GradingWheel: Codable, Equatable {
    package var hue: Double = 0
    package var saturation: Double = 0
    package var luminance: Double = 0

    package init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
        self.hue = hue; self.saturation = saturation; self.luminance = luminance
    }
}
package struct ColorGrading: Codable, Equatable {
    package var shadows = GradingWheel()
    package var midtones = GradingWheel()
    package var highlights = GradingWheel()
    package var balance: Double = 0
    package var blending: Double = 50

    package init(shadows: GradingWheel = GradingWheel(), midtones: GradingWheel = GradingWheel(), highlights: GradingWheel = GradingWheel(), balance: Double = 0, blending: Double = 50) {
        self.shadows = shadows; self.midtones = midtones; self.highlights = highlights; self.balance = balance; self.blending = blending
    }
}
package struct PointColorSettings: Codable, Equatable {
    package var enabled = false
    package var color: [Double] = [0.5, 0.5, 0.5]
    package var tolerance: Double = 0.25
    package var hue: Double = 0
    package var saturation: Double = 0
    package var luminance: Double = 0

    package init(enabled: Bool = false, color: [Double] = [0.5, 0.5, 0.5], tolerance: Double = 0.25, hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
        self.enabled = enabled; self.color = color; self.tolerance = tolerance; self.hue = hue; self.saturation = saturation; self.luminance = luminance
    }
}
package struct CalibrationSettings: Codable, Equatable {
    package var redHue: Double = 0
    package var redSaturation: Double = 0
    package var greenHue: Double = 0
    package var greenSaturation: Double = 0
    package var blueHue: Double = 0
    package var blueSaturation: Double = 0
    package var shadowTint: Double = 0

    package init(redHue: Double = 0, redSaturation: Double = 0, greenHue: Double = 0, greenSaturation: Double = 0, blueHue: Double = 0, blueSaturation: Double = 0, shadowTint: Double = 0) {
        self.redHue = redHue; self.redSaturation = redSaturation; self.greenHue = greenHue; self.greenSaturation = greenSaturation; self.blueHue = blueHue; self.blueSaturation = blueSaturation; self.shadowTint = shadowTint
    }
}

package enum MaskOperation: String, Codable, CaseIterable, Identifiable {
    case add, subtract, intersect
    package var id: String { rawValue }
    package var title: String { switch self { case .add: return "添加"; case .subtract: return "减去"; case .intersect: return "相交" } }
}
package struct MaskComponent: Codable, Equatable, Identifiable {
    package var id = UUID()
    package var kind: MaskKind = .brush
    package var operation: MaskOperation = .add
    package var inverted = false
    package var feather: Double = 0.75
    package var brushSize: Double = 0.07
    package var brushVersion: Int? = 2
    package var raster: PortableMaskRaster? = nil
    package var edgeStrokes: [EdgeBrushStroke] = []
    package var start = UnitPoint2D(x: 0.3, y: 0.3)
    package var end = UnitPoint2D(x: 0.7, y: 0.7)
    package var strokes: [[UnitPoint2D]] = []
    package var erasedStrokes: [[UnitPoint2D]] = []
    package var flow: Double = 1
    package var density: Double = 1
    package var rangeColor: [Double] = [0.5, 0.5, 0.5]
    package var rangeTolerance: Double = 0.25
    package var luminanceLow: Double = 0.25
    package var luminanceHigh: Double = 0.75

    package init(id: UUID = UUID(), kind: MaskKind = .brush, operation: MaskOperation = .add, feather: Double = 0.75, brushSize: Double = 0.07, start: UnitPoint2D = UnitPoint2D(x: 0.3, y: 0.3), end: UnitPoint2D = UnitPoint2D(x: 0.7, y: 0.7), strokes: [[UnitPoint2D]] = [], erasedStrokes: [[UnitPoint2D]] = [], flow: Double = 1, density: Double = 1, rangeColor: [Double] = [0.5, 0.5, 0.5], rangeTolerance: Double = 0.25, luminanceLow: Double = 0.25, luminanceHigh: Double = 0.75) {
        self.id = id; self.kind = kind; self.operation = operation; self.feather = feather; self.brushSize = brushSize; self.start = start; self.end = end; self.strokes = strokes; self.erasedStrokes = erasedStrokes; self.flow = flow; self.density = density; self.rangeColor = rangeColor; self.rangeTolerance = rangeTolerance; self.luminanceLow = luminanceLow; self.luminanceHigh = luminanceHigh
    }
}
package struct SavedSnapshot: Codable, Equatable, Identifiable {
    package var id = UUID()
    package var name: String
    package var state: EditState

    package init(id: UUID = UUID(), name: String, state: EditState) {
        self.id = id; self.name = name; self.state = state
    }
}
package enum OutputFormat: String, Codable, CaseIterable, Identifiable {
    case jpeg, png, tiff
    package var id: String { rawValue }
    package var title: String { rawValue.uppercased() }
    package var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
}
package enum OutputColorSpace: String, Codable, CaseIterable, Identifiable {
    case sRGB, displayP3, adobeRGB
    package var id: String { rawValue }
    package var title: String { switch self { case .sRGB: return "标准 RGB"; case .displayP3: return "显示器 P3"; case .adobeRGB: return "Adobe RGB" } }
}
package struct ExportOptions: Codable, Equatable {
    package var format: OutputFormat = .jpeg
    package var quality: Double = 0.95
    package var bitDepth: Int = 8
    package var colorSpace: OutputColorSpace = .sRGB
    package var longEdge: Int = 0
    package var dontEnlarge = true
    package var outputSharpening: Double = 0
    package var watermark = ""
    package var includeMetadata = true
    package var removeGPS = true

    package init(format: OutputFormat = .jpeg, quality: Double = 0.95, bitDepth: Int = 8, colorSpace: OutputColorSpace = .sRGB, longEdge: Int = 0, dontEnlarge: Bool = true, outputSharpening: Double = 0, watermark: String = "", includeMetadata: Bool = true, removeGPS: Bool = true) {
        self.format = format; self.quality = quality; self.bitDepth = bitDepth; self.colorSpace = colorSpace; self.longEdge = longEdge; self.dontEnlarge = dontEnlarge; self.outputSharpening = outputSharpening; self.watermark = watermark; self.includeMetadata = includeMetadata; self.removeGPS = removeGPS
    }
}

extension Adjustments {
    private enum CodingKeys: String, CodingKey { case exposure, contrast, highlights, shadows, whites, blacks, temperature, tint, vibrance, saturation, clarity, sharpness, vignette, texture, dehaze, noiseReduction, colorNoiseReduction, sharpenRadius, sharpenDetail, sharpenMasking, grain, grainSize, grainRoughness, vignetteMidpoint, vignetteFeather, vignetteRoundness, distortion, defringe }
    package init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try values.decodeIfPresent(type(of: exposure), forKey: .exposure) ?? exposure
        contrast = try values.decodeIfPresent(type(of: contrast), forKey: .contrast) ?? contrast
        highlights = try values.decodeIfPresent(type(of: highlights), forKey: .highlights) ?? highlights
        shadows = try values.decodeIfPresent(type(of: shadows), forKey: .shadows) ?? shadows
        whites = try values.decodeIfPresent(type(of: whites), forKey: .whites) ?? whites
        blacks = try values.decodeIfPresent(type(of: blacks), forKey: .blacks) ?? blacks
        temperature = try values.decodeIfPresent(type(of: temperature), forKey: .temperature) ?? temperature
        tint = try values.decodeIfPresent(type(of: tint), forKey: .tint) ?? tint
        vibrance = try values.decodeIfPresent(type(of: vibrance), forKey: .vibrance) ?? vibrance
        saturation = try values.decodeIfPresent(type(of: saturation), forKey: .saturation) ?? saturation
        clarity = try values.decodeIfPresent(type(of: clarity), forKey: .clarity) ?? clarity
        sharpness = try values.decodeIfPresent(type(of: sharpness), forKey: .sharpness) ?? sharpness
        vignette = try values.decodeIfPresent(type(of: vignette), forKey: .vignette) ?? vignette
        texture = try values.decodeIfPresent(type(of: texture), forKey: .texture) ?? texture
        dehaze = try values.decodeIfPresent(type(of: dehaze), forKey: .dehaze) ?? dehaze
        noiseReduction = try values.decodeIfPresent(type(of: noiseReduction), forKey: .noiseReduction) ?? noiseReduction
        colorNoiseReduction = try values.decodeIfPresent(type(of: colorNoiseReduction), forKey: .colorNoiseReduction) ?? colorNoiseReduction
        sharpenRadius = try values.decodeIfPresent(type(of: sharpenRadius), forKey: .sharpenRadius) ?? sharpenRadius
        sharpenDetail = try values.decodeIfPresent(type(of: sharpenDetail), forKey: .sharpenDetail) ?? sharpenDetail
        sharpenMasking = try values.decodeIfPresent(type(of: sharpenMasking), forKey: .sharpenMasking) ?? sharpenMasking
        grain = try values.decodeIfPresent(type(of: grain), forKey: .grain) ?? grain
        grainSize = try values.decodeIfPresent(type(of: grainSize), forKey: .grainSize) ?? grainSize
        grainRoughness = try values.decodeIfPresent(type(of: grainRoughness), forKey: .grainRoughness) ?? grainRoughness
        vignetteMidpoint = try values.decodeIfPresent(type(of: vignetteMidpoint), forKey: .vignetteMidpoint) ?? vignetteMidpoint
        vignetteFeather = try values.decodeIfPresent(type(of: vignetteFeather), forKey: .vignetteFeather) ?? vignetteFeather
        vignetteRoundness = try values.decodeIfPresent(type(of: vignetteRoundness), forKey: .vignetteRoundness) ?? vignetteRoundness
        distortion = try values.decodeIfPresent(type(of: distortion), forKey: .distortion) ?? distortion
        defringe = try values.decodeIfPresent(type(of: defringe), forKey: .defringe) ?? defringe
    }
}

extension LocalMask {
    private enum CodingKeys: String, CodingKey { case id, name, kind, enabled, inverted, overlayVisible, handlesVisible, overlayColor, groupID, groupName, automaticKind, automaticIndex, opacity, feather, brushSize, brushVersion, raster, edgeStrokes, start, end, strokes, erasedStrokes, flow, density, rangeColor, rangeTolerance, luminanceLow, luminanceHigh, components, adjustments, hsl, disabledSections }
    package init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(type(of: id), forKey: .id) ?? id
        name = try values.decodeIfPresent(type(of: name), forKey: .name) ?? name
        kind = try values.decodeIfPresent(type(of: kind), forKey: .kind) ?? kind
        enabled = try values.decodeIfPresent(type(of: enabled), forKey: .enabled) ?? enabled
        inverted = try values.decodeIfPresent(type(of: inverted), forKey: .inverted) ?? inverted
        overlayVisible = try values.decodeIfPresent(Bool.self, forKey: .overlayVisible) ?? true
        handlesVisible = try values.decodeIfPresent(Bool.self, forKey: .handlesVisible) ?? true
        overlayColor = try values.decodeIfPresent([Double].self, forKey: .overlayColor) ?? overlayColor
        groupID = try values.decodeIfPresent(UUID.self, forKey: .groupID)
        groupName = try values.decodeIfPresent(String.self, forKey: .groupName)
        automaticKind = try values.decodeIfPresent(AutomaticMaskKind.self, forKey: .automaticKind)
        automaticIndex = try values.decodeIfPresent(Int.self, forKey: .automaticIndex)
        opacity = try values.decodeIfPresent(type(of: opacity), forKey: .opacity) ?? opacity
        feather = try values.decodeIfPresent(type(of: feather), forKey: .feather) ?? feather
        brushSize = try values.decodeIfPresent(type(of: brushSize), forKey: .brushSize) ?? brushSize
        brushVersion = try values.decodeIfPresent(Int.self, forKey: .brushVersion) ?? 1
        raster = try values.decodeIfPresent(PortableMaskRaster.self, forKey: .raster)
        edgeStrokes = try values.decodeIfPresent([EdgeBrushStroke].self, forKey: .edgeStrokes) ?? []
        start = try values.decodeIfPresent(type(of: start), forKey: .start) ?? start
        end = try values.decodeIfPresent(type(of: end), forKey: .end) ?? end
        strokes = try values.decodeIfPresent(type(of: strokes), forKey: .strokes) ?? strokes
        erasedStrokes = try values.decodeIfPresent(type(of: erasedStrokes), forKey: .erasedStrokes) ?? erasedStrokes
        flow = try values.decodeIfPresent(type(of: flow), forKey: .flow) ?? flow
        density = try values.decodeIfPresent(type(of: density), forKey: .density) ?? density
        rangeColor = try values.decodeIfPresent(type(of: rangeColor), forKey: .rangeColor) ?? rangeColor
        rangeTolerance = try values.decodeIfPresent(type(of: rangeTolerance), forKey: .rangeTolerance) ?? rangeTolerance
        luminanceLow = try values.decodeIfPresent(type(of: luminanceLow), forKey: .luminanceLow) ?? luminanceLow
        luminanceHigh = try values.decodeIfPresent(type(of: luminanceHigh), forKey: .luminanceHigh) ?? luminanceHigh
        components = try values.decodeIfPresent(type(of: components), forKey: .components) ?? components
        adjustments = try values.decodeIfPresent(type(of: adjustments), forKey: .adjustments) ?? adjustments
        hsl = try values.decodeIfPresent([HSLBand].self, forKey: .hsl) ?? HSLBand.defaults
        disabledSections = try values.decodeIfPresent(Set<AdjustmentSection>.self, forKey: .disabledSections) ?? []
    }
}

extension EditState {
    private enum CodingKeys: String, CodingKey { case adjustments, masks, repairs, crop, quarterTurns, flipHorizontal, geometry, curves, hsl, grading, pointColor, calibration, lut, disabledSections }
    package init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        adjustments = try values.decodeIfPresent(type(of: adjustments), forKey: .adjustments) ?? adjustments
        masks = try values.decodeIfPresent(type(of: masks), forKey: .masks) ?? masks
        repairs = try values.decodeIfPresent([RepairStroke].self,forKey:.repairs) ?? []
        crop = try values.decodeIfPresent(type(of: crop), forKey: .crop) ?? crop
        quarterTurns = try values.decodeIfPresent(type(of: quarterTurns), forKey: .quarterTurns) ?? quarterTurns
        flipHorizontal = try values.decodeIfPresent(type(of: flipHorizontal), forKey: .flipHorizontal) ?? flipHorizontal
        geometry = try values.decodeIfPresent(type(of: geometry), forKey: .geometry) ?? geometry
        curves = try values.decodeIfPresent(type(of: curves), forKey: .curves) ?? curves
        hsl = try values.decodeIfPresent(type(of: hsl), forKey: .hsl) ?? hsl
        grading = try values.decodeIfPresent(type(of: grading), forKey: .grading) ?? grading
        pointColor = try values.decodeIfPresent(type(of: pointColor), forKey: .pointColor) ?? pointColor
        calibration = try values.decodeIfPresent(type(of: calibration), forKey: .calibration) ?? calibration
        lut = try values.decodeIfPresent(LUTSettings.self, forKey: .lut) ?? .init()
        disabledSections = try values.decodeIfPresent(Set<AdjustmentSection>.self, forKey: .disabledSections) ?? []
    }
}

extension PhotoProject {
    private enum CodingKeys: String, CodingKey { case formatVersion, sourceName, sourceData, edits, snapshots, virtualCopies, history }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        sourceName = try c.decode(String.self, forKey: .sourceName)
        sourceData = try c.decode(Data.self, forKey: .sourceData)
        edits = try c.decode(EditState.self, forKey: .edits)
        snapshots = try c.decodeIfPresent([SavedSnapshot].self, forKey: .snapshots) ?? []
        virtualCopies = try c.decodeIfPresent([SavedSnapshot].self, forKey: .virtualCopies) ?? []
        history = try c.decodeIfPresent([EditState].self, forKey: .history) ?? []
    }
}


extension GeometrySettings {
    private enum CodingKeys: String, CodingKey { case angle, vertical, horizontal, aspect, scale, offsetX, offsetY, autoCrop }
    package init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        angle = try c.decodeIfPresent(Double.self,forKey:.angle) ?? angle
        vertical = try c.decodeIfPresent(Double.self,forKey:.vertical) ?? vertical
        horizontal = try c.decodeIfPresent(Double.self,forKey:.horizontal) ?? horizontal
        aspect = try c.decodeIfPresent(Double.self,forKey:.aspect) ?? aspect
        scale = try c.decodeIfPresent(Double.self,forKey:.scale) ?? scale
        offsetX = try c.decodeIfPresent(Double.self,forKey:.offsetX) ?? offsetX
        offsetY = try c.decodeIfPresent(Double.self,forKey:.offsetY) ?? offsetY
        autoCrop = try c.decodeIfPresent(Bool.self,forKey:.autoCrop) ?? false
    }
}

extension LocalMask {
    package var shape: MaskComponent {
        get {
            var s = MaskComponent()
            s.id = id; s.kind = kind; s.raster = raster; s.edgeStrokes = edgeStrokes; s.brushVersion = brushVersion; s.feather = feather; s.brushSize = brushSize
            s.start = start; s.end = end; s.strokes = strokes; s.erasedStrokes = erasedStrokes
            s.flow = flow; s.density = density; s.rangeColor = rangeColor
            s.rangeTolerance = rangeTolerance; s.luminanceLow = luminanceLow; s.luminanceHigh = luminanceHigh
            return s
        }
        set {
            kind = newValue.kind; raster = newValue.raster; edgeStrokes = newValue.edgeStrokes; brushVersion = newValue.brushVersion; feather = newValue.feather; brushSize = newValue.brushSize
            start = newValue.start; end = newValue.end; strokes = newValue.strokes; erasedStrokes = newValue.erasedStrokes
            flow = newValue.flow; density = newValue.density; rangeColor = newValue.rangeColor
            rangeTolerance = newValue.rangeTolerance; luminanceLow = newValue.luminanceLow; luminanceHigh = newValue.luminanceHigh
        }
    }
}


extension MaskComponent {
    private enum CodingKeys:String,CodingKey {case id,kind,operation,inverted,feather,brushSize,brushVersion,raster,edgeStrokes,start,end,strokes,erasedStrokes,flow,density,rangeColor,rangeTolerance,luminanceLow,luminanceHigh}
    package init(from decoder:Decoder) throws {
        self.init()
        let c=try decoder.container(keyedBy:CodingKeys.self)
        id=try c.decodeIfPresent(UUID.self,forKey:.id) ?? id
        kind=try c.decodeIfPresent(type(of:kind),forKey:.kind) ?? kind
        operation=try c.decodeIfPresent(type(of:operation),forKey:.operation) ?? operation
        inverted=try c.decodeIfPresent(Bool.self,forKey:.inverted) ?? false
        feather=try c.decodeIfPresent(type(of:feather),forKey:.feather) ?? feather
        brushSize=try c.decodeIfPresent(type(of:brushSize),forKey:.brushSize) ?? brushSize
        brushVersion=try c.decodeIfPresent(Int.self,forKey:.brushVersion) ?? 1
        raster=try c.decodeIfPresent(PortableMaskRaster.self,forKey:.raster)
        edgeStrokes=try c.decodeIfPresent(type(of:edgeStrokes),forKey:.edgeStrokes) ?? edgeStrokes
        start=try c.decodeIfPresent(type(of:start),forKey:.start) ?? start
        end=try c.decodeIfPresent(type(of:end),forKey:.end) ?? end
        strokes=try c.decodeIfPresent(type(of:strokes),forKey:.strokes) ?? strokes
        erasedStrokes=try c.decodeIfPresent(type(of:erasedStrokes),forKey:.erasedStrokes) ?? erasedStrokes
        flow=try c.decodeIfPresent(type(of:flow),forKey:.flow) ?? flow
        density=try c.decodeIfPresent(type(of:density),forKey:.density) ?? density
        rangeColor=try c.decodeIfPresent(type(of:rangeColor),forKey:.rangeColor) ?? rangeColor
        rangeTolerance=try c.decodeIfPresent(type(of:rangeTolerance),forKey:.rangeTolerance) ?? rangeTolerance
        luminanceLow=try c.decodeIfPresent(type(of:luminanceLow),forKey:.luminanceLow) ?? luminanceLow
        luminanceHigh=try c.decodeIfPresent(type(of:luminanceHigh),forKey:.luminanceHigh) ?? luminanceHigh
    }
}


extension ExportOptions {
    private enum CodingKeys: String, CodingKey { case format, quality, bitDepth, colorSpace, longEdge, dontEnlarge, outputSharpening, watermark, includeMetadata, removeGPS }
    package init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(OutputFormat.self, forKey: .format) ?? format
        quality = try c.decodeIfPresent(Double.self, forKey: .quality) ?? quality
        bitDepth = try c.decodeIfPresent(Int.self, forKey: .bitDepth) ?? bitDepth
        colorSpace = try c.decodeIfPresent(OutputColorSpace.self, forKey: .colorSpace) ?? colorSpace
        longEdge = try c.decodeIfPresent(Int.self, forKey: .longEdge) ?? longEdge
        dontEnlarge = try c.decodeIfPresent(Bool.self, forKey: .dontEnlarge) ?? dontEnlarge
        outputSharpening = try c.decodeIfPresent(Double.self, forKey: .outputSharpening) ?? outputSharpening
        watermark = try c.decodeIfPresent(String.self, forKey: .watermark) ?? watermark
        includeMetadata = try c.decodeIfPresent(Bool.self, forKey: .includeMetadata) ?? includeMetadata
        // Old export presets retain their previous metadata policy.
        removeGPS = try c.decodeIfPresent(Bool.self, forKey: .removeGPS) ?? false
    }
}
