import Foundation

/// Export policy shared by platform adapters. Never mutates source metadata.
package enum ExportMetadata {
    package static func filtered(_ source: [String: Any], removeGPS: Bool) -> [String: Any] {
        guard removeGPS else { return source }
        let locationKeys: Set<String> = ["latitude", "longitude", "altitude", "location", "locationcreated", "locationshown", "sublocation", "city", "provinceState".lowercased(), "countryprimarylocationname", "countryprimarylocationcode"]
        return source.reduce(into: [:]) { result, entry in
            let key = entry.key.lowercased().filter { $0.isLetter || $0.isNumber }
            guard !key.contains("gps"), !locationKeys.contains(key) else { return }
            if let nested = entry.value as? [String: Any] { result[entry.key] = filtered(nested, removeGPS: true) }
            else if let nested = entry.value as? [[String: Any]] { result[entry.key] = nested.map { filtered($0, removeGPS: true) } }
            else { result[entry.key] = entry.value }
        }
    }
}

package struct ScopeAnalysis {
    package static let size = 128
    package var waveform = [Double](repeating: 0, count: size * size)
    package var parade = [[Double]](repeating: [Double](repeating: 0, count: size * size), count: 3)
    package var vectorscope = [Double](repeating: 0, count: size * size)
    package var sampleCount = 0
    /// Input is display-encoded sRGB, premultiplied RGBA8, top row first.
    package static func analyze(rgba: [UInt8], width: Int, height: Int) -> ScopeAnalysis {
        var result = ScopeAnalysis()
        guard width > 0, height > 0, width <= 1_048_576 / height, rgba.count == width * height * 4 else { return result }
        let n = size
        func bin(_ v: Double) -> Int { min(n-1, max(0, Int((EngineColor.clamp(v) * Double(n-1)).rounded()))) }
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4, alpha = Double(rgba[i+3])
            guard alpha > 0 else { continue }
            let r = min(1,Double(rgba[i])/alpha), g = min(1,Double(rgba[i+1])/alpha), b = min(1,Double(rgba[i+2])/alpha)
            let luma = 0.2126*r + 0.7152*g + 0.0722*b
            let column = width == 1 ? 0 : x*(n-1)/(width-1)
            result.waveform[(n-1-bin(luma))*n+column] += 1
            for (c,v) in [r,g,b].enumerated() { result.parade[c][(n-1-bin(v))*n+column] += 1 }
            let cb = (b-luma)/1.8556, cr = (r-luma)/1.5748
            result.vectorscope[(n-1-bin(cr+0.5))*n+bin(cb+0.5)] += 1
            result.sampleCount += 1
        } }
        return result
    }
    package static func density(_ bins: [Double]) -> [Double] {
        let peak = max(1,bins.max() ?? 1), divisor = log1p(peak)
        return bins.map { log1p(max(0,$0))/divisor }
    }
}

extension CubeLUT {
    package init(name: String, size: Int, values: [Float]) throws {
        self.name=name; self.size=size; self.values=values; domainMin=[0,0,0]; domainMax=[1,1,1]
        guard isValid else { throw Failure.invalid("Invalid LUT samples") }
    }
    /// .cube order is red fastest, then green, then blue; decimal separator is fixed.
    package func serialized() throws -> String {
        guard isValid else { throw Failure.invalid("Invalid LUT") }
        let title = name.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        var text = "# LumaLab global color transform; sRGB input and output\nTITLE \"\(title)\"\nLUT_3D_SIZE \(size)\nDOMAIN_MIN \(domainMin.map { String($0) }.joined(separator: " "))\nDOMAIN_MAX \(domainMax.map { String($0) }.joined(separator: " "))\n"
        for i in stride(from: 0, to: values.count, by: 3) {
            text += String(format: "%.7f %.7f %.7f\n", locale: Locale(identifier: "en_US_POSIX"), values[i], values[i+1], values[i+2])
        }
        return text
    }
}

extension EditState {
    /// A static RGB lookup cannot represent geometry, local or spatial effects.
    package var lutExportState: EditState {
        var result = renderingState
        result.masks=[]; result.repairs=[]; result.crop = .full; result.geometry = .init()
        result.quarterTurns=0; result.flipHorizontal=false
        result.adjustments.clarity=0; result.adjustments.texture=0; result.adjustments.sharpness=0
        result.adjustments.noiseReduction=0; result.adjustments.colorNoiseReduction=0
        result.adjustments.grain=0; result.adjustments.vignette=0
        result.adjustments.distortion=0; result.adjustments.defringe=0
        return result
    }
}
