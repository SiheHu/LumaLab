import Foundation
import LumaCore

package enum PortableBrush {
    package static func raster(strokes: [[UnitPoint2D]], width: Int, height: Int, diameterFraction: Double, feather: Double) -> Data {
        guard width > 0, height > 0, width <= 32768, height <= 32768 else { return Data() }
        var bytes = Data(repeating: 0, count: width * height)
        let radius = min(3, max(0.001, diameterFraction)) * Double(min(width, height)) / 2
        bytes.withUnsafeMutableBytes { storage in
            guard let out = storage.bindMemory(to: UInt8.self).baseAddress else { return }
            for stroke in strokes where !stroke.isEmpty {
                let points = stroke.filter { $0.x.isFinite && $0.y.isFinite }
                guard let first = points.first else { continue }
                var last = first
                for point in points {
                    luma_brush_segment(out, Int32(width), Int32(height), last.x * Double(width), last.y * Double(height), point.x * Double(width), point.y * Double(height), radius, feather)
                    last = point
                }
            }
        }
        return bytes
    }
}
