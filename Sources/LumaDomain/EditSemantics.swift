import Foundation

package enum AdjustmentSection: String, Codable, CaseIterable {
    case allAdjustments, whiteBalance, light, color, effects, grain, vignette, detail, optics
    case curves, hsl, pointColor, grading, calibration, geometry, transform, masks, repairs

    package var adjustmentKeys: [WritableKeyPath<Adjustments, Double>] {
        switch self {
        case .whiteBalance: return [\.temperature, \.tint]
        case .light: return [\.exposure, \.contrast, \.highlights, \.shadows, \.whites, \.blacks]
        case .color: return [\.vibrance, \.saturation]
        case .effects: return [\.texture, \.clarity, \.dehaze]
        case .grain: return [\.grain, \.grainSize, \.grainRoughness]
        case .vignette: return [\.vignette, \.vignetteMidpoint, \.vignetteFeather, \.vignetteRoundness]
        case .detail: return [\.sharpness, \.sharpenRadius, \.sharpenDetail, \.sharpenMasking, \.noiseReduction, \.colorNoiseReduction]
        case .optics: return [\.distortion, \.defringe]
        default: return []
        }
    }
}

extension Adjustments {
    package mutating func reset(_ section: AdjustmentSection) {
        for key in section.adjustmentKeys { self[keyPath: key] = Adjustments.neutral[keyPath: key] }
    }
    package func visible(excluding hidden: Set<AdjustmentSection>) -> Adjustments {
        if hidden.contains(.allAdjustments) {return .neutral}
        var result = self
        for section in hidden { result.reset(section) }
        return result
    }
}

extension EditState {
    package var renderingState: EditState {
        var result = self
        result.adjustments = adjustments.visible(excluding: disabledSections)
        if disabledSections.contains(.curves) { result.curves = .init() }
        if disabledSections.contains(.hsl) { result.hsl = HSLBand.defaults }
        if disabledSections.contains(.pointColor) { result.pointColor = .init() }
        if disabledSections.contains(.grading) { result.grading = .init() }
        if disabledSections.contains(.calibration) { result.calibration = .init() }
        if disabledSections.contains(.allAdjustments) {
            result.curves = .init();result.hsl = HSLBand.defaults;result.pointColor = .init()
            result.grading = .init();result.calibration = .init();result.lut.enabled=false
        }
        if disabledSections.contains(.geometry) {
            result.geometry = .init(); result.crop = .full; result.quarterTurns = 0; result.flipHorizontal = false
        } else if disabledSections.contains(.transform) { result.geometry = .init() }
        if disabledSections.contains(.repairs) {result.repairs=[]}
        if disabledSections.contains(.masks) { result.masks = [] }
        else {
            for i in result.masks.indices {
                result.masks[i].adjustments = masks[i].adjustments.visible(excluding: masks[i].disabledSections)
                if masks[i].disabledSections.contains(.hsl) || masks[i].disabledSections.contains(.allAdjustments) { result.masks[i].hsl = HSLBand.defaults }
            }
        }
        return result
    }
    package mutating func reset(_ section: AdjustmentSection) {
        adjustments.reset(section)
        switch section {
        case .repairs: repairs=[]
        case .curves: curves = .init()
        case .hsl: hsl = HSLBand.defaults
        case .pointColor: pointColor = .init()
        case .grading: grading = .init()
        case .calibration: calibration = .init()
        case .transform: geometry = .init()
        case .geometry: geometry = .init(); crop = .full; quarterTurns = 0; flipHorizontal = false
        default: break
        }
    }
}

package enum NumericInput {
    package static func limits(for range: ClosedRange<Double>, factor: Double = 3) -> ClosedRange<Double> {
        let lower = range.lowerBound < 0 ? range.lowerBound * factor : range.lowerBound / factor
        return lower...(range.upperBound * factor)
    }
    package static func parse(_ text: String, range: ClosedRange<Double>, multiplier: Double = 1, factor: Double = 3) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "，",with:".").replacingOccurrences(of:",",with:".").replacingOccurrences(of:"−",with:"-")
        guard let value = Double(normalized), value.isFinite, multiplier > 0 else { return nil }
        let allowed = limits(for:range,factor:factor)
        return min(allowed.upperBound,max(allowed.lowerBound,value / multiplier))
    }
}

package enum CurveEditing {
    package static func insert(_ point: UnitPoint2D, into points: inout [UnitPoint2D]) -> Int? {
        guard points.count < 64, point.x > 0.005, point.x < 0.995,
              !points.contains(where: { abs($0.x-point.x) < 0.005 }) else { return nil }
        let next = UnitPoint2D(x:point.x,y:min(1,max(0,point.y)))
        let index = points.firstIndex(where: { $0.x > point.x }) ?? points.count
        points.insert(next,at:index); return index
    }
    package static func remove(_ index: Int, from points: inout [UnitPoint2D]) {
        guard index > 0, index < points.count-1 else { return }
        points.remove(at:index)
    }
}

package struct EditingCheckpoint {
    package var edits = EditState()
    package var snapshots: [SavedSnapshot] = []
    package var virtualCopies: [SavedSnapshot] = []
    package var history: [EditState] = [.init()]
    package var historyIndex = 0

    package init(edits: EditState = EditState(), snapshots: [SavedSnapshot] = [], virtualCopies: [SavedSnapshot] = [], history: [EditState] = [.init()], historyIndex: Int = 0) {
        self.edits = edits; self.snapshots = snapshots; self.virtualCopies = virtualCopies; self.history = history; self.historyIndex = historyIndex
    }
}
