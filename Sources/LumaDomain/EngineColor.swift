import Foundation

/// Original color transforms, intentionally independent of Adobe's algorithms.
package enum EngineColor {
    package static func cube(dimension: Int = 24, transform: (Double, Double, Double) -> (Double, Double, Double)) -> Data {
        var values = [Float](); values.reserveCapacity(dimension * dimension * dimension * 4)
        for b in 0..<dimension { for g in 0..<dimension { for r in 0..<dimension {
            let result = transform(Double(r) / Double(dimension - 1), Double(g) / Double(dimension - 1), Double(b) / Double(dimension - 1))
            values.append(Float(clamp(result.0))); values.append(Float(clamp(result.1))); values.append(Float(clamp(result.2))); values.append(1)
        } } }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
    package static func transform(_ r: Double, _ g: Double, _ b: Double, edits: EditState) -> (Double, Double, Double) {
        let prepared=PreparedColorTransform(edits)
        return prepared.apply(r,g,b)
    }
    package static func transformPrepared(_ r: Double, _ g: Double, _ b: Double, edits: EditState, splines: [CurveSpline]) -> (Double, Double, Double) {
        let c = edits.curves
        func tone(_ v: Double) -> Double {
            let centers = [0.10, 0.35, 0.65, 0.9]
            let controls = [c.shadows, c.darks, c.lights, c.highlights]
            var value = splines[0].value(at:v)
            for i in 0..<4 { value += controls[i] / 100 * 0.13 * exp(-pow((v - centers[i]) / 0.2, 2)) }
            return clamp(value)
        }
        var red = splines[1].value(at:tone(r)), green = splines[2].value(at:tone(g)), blue = splines[3].value(at:tone(b))
        let original = hsl(red, green, blue)
        var hue = original.0, saturation = original.1, luminance = original.2
        let centers = [0.0, 1.0 / 12, 1.0 / 6, 1.0 / 3, 0.5, 2.0 / 3, 0.75, 5.0 / 6]
        for (i, band) in edits.hsl.prefix(8).enumerated() {
            let distance = hueDistance(original.0, centers[i])
            let weight = smooth(1 - distance / 0.14) * min(1, original.1 * 5)
            hue += band.hue / 100 * 0.10 * weight
            saturation += band.saturation / 100 * 0.55 * weight
            luminance += band.luminance / 100 * 0.22 * weight
        }
        let point = edits.pointColor
        if point.enabled && point.color.count >= 3 {
            let distance = sqrt(pow(r - point.color[0], 2) + pow(g - point.color[1], 2) + pow(b - point.color[2], 2)) / sqrt(3)
            let weight = 1 - smooth(distance / max(0.005, point.tolerance))
            hue += point.hue / 100 * 0.20 * weight
            saturation += point.saturation / 100 * 0.6 * weight
            luminance += point.luminance / 100 * 0.25 * weight
        }
        let calibration = edits.calibration
        for (center, deltaHue, deltaSaturation) in [(0.0, calibration.redHue, calibration.redSaturation), (1.0 / 3, calibration.greenHue, calibration.greenSaturation), (2.0 / 3, calibration.blueHue, calibration.blueSaturation)] {
            let weight = smooth(1 - hueDistance(original.0, center) / 0.4) * min(1, original.1 * 5)
            hue += deltaHue / 100 * 0.12 * weight
            saturation += deltaSaturation / 100 * 0.5 * weight
        }
        (red, green, blue) = rgb(hue, clamp(saturation), clamp(luminance))
        let grade = edits.grading
        let level = clamp(0.2126 * red + 0.7152 * green + 0.0722 * blue + grade.balance / 400)
        let softness = 0.14 + clamp(grade.blending / 100) * 0.45
        let shadow = 1 - smooth((level - (0.33 - softness)) / (2 * softness))
        let highlight = smooth((level - (0.67 - softness)) / (2 * softness))
        let middle = max(0, 1 - shadow - highlight)
        for (wheel, weight) in [(grade.shadows, shadow), (grade.midtones, middle), (grade.highlights, highlight)] {
            let tint = rgb(wheel.hue / 360, 1, 0.5)
            let strength = clamp(wheel.saturation / 100) * 0.32 * weight
            let lift = wheel.luminance / 100 * 0.18 * weight
            red += (tint.0 - 0.5) * strength + lift
            green += (tint.1 - 0.5) * strength + lift
            blue += (tint.2 - 0.5) * strength + lift
        }
        let tint = calibration.shadowTint / 100 * 0.1 * (1 - level)
        red += tint * 0.4; green -= tint; blue += tint * 0.4
        return (clamp(red), clamp(green), clamp(blue))
    }
    /// Local, shape-preserving cubic Hermite interpolation. A node changes only
    /// its neighboring segments/slopes, avoiding global-polynomial oscillation.
    package static func curve(_ value: Double, points: [UnitPoint2D]) -> Double {
        CurveSpline(points).value(at: value)
    }
    package static func hsl(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let hi = max(r, g, b), lo = min(r, g, b), d = hi - lo, light = (hi + lo) / 2
        if d < 0.000001 { return (0, 0, light) }
        let saturation = d / max(0.000001, 1 - abs(2 * light - 1))
        var hue: Double
        if hi == r { hue = (g - b) / d + (g < b ? 6 : 0) }
        else if hi == g { hue = (b - r) / d + 2 }
        else { hue = (r - g) / d + 4 }
        return (hue / 6, saturation, light)
    }
    package static func rgb(_ hue: Double, _ saturation: Double, _ light: Double) -> (Double, Double, Double) {
        let h = (hue - floor(hue)) * 6
        let chroma = (1 - abs(2 * light - 1)) * saturation
        let x = chroma * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)), m = light - chroma / 2
        let c: (Double, Double, Double)
        switch h { case ..<1: c = (chroma, x, 0); case ..<2: c = (x, chroma, 0); case ..<3: c = (0, chroma, x); case ..<4: c = (0, x, chroma); case ..<5: c = (x, 0, chroma); default: c = (chroma, 0, x) }
        return (c.0 + m, c.1 + m, c.2 + m)
    }
    package static func hueDistance(_ a: Double, _ b: Double) -> Double { let d = abs(a - b); return min(d, 1 - d) }
    package static func clamp(_ v: Double) -> Double { v.isFinite ? min(1, max(0, v)) : 0 }
    package static func smooth(_ v: Double) -> Double { let t = clamp(v); return t * t * (3 - 2 * t) }
}

package struct PreparedColorTransform {
    private let edits:EditState
    private let splines:[CurveSpline]
    package init(_ edits:EditState) {
        self.edits=edits
        splines=[edits.curves.master,edits.curves.red,edits.curves.green,edits.curves.blue].map {CurveSpline($0)}
    }
    package func apply(_ r:Double,_ g:Double,_ b:Double)->(Double,Double,Double) {
        EngineColor.transformPrepared(r,g,b,edits:edits,splines:splines)
    }
}
