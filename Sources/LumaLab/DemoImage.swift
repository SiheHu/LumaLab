import LumaDomain
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Original procedural artwork, generated locally without Adobe assets.
enum DemoImage {
    static func make() throws -> Data {
        let w = 1600, h = 1100
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                 space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ImagePipeline.PipelineError.renderFailed
        }
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
            CGColor(colorSpace: space, components: [r, g, b, a])!
        }
        func gradient(_ colors: [CGColor], _ from: CGPoint, _ to: CGPoint) {
            let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
            cg.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        func polygon(_ points: [CGPoint], _ fill: CGColor) {
            cg.beginPath(); cg.addLines(between: points); cg.closePath(); cg.setFillColor(fill); cg.fillPath()
        }
        gradient([color(0.97, 0.71, 0.45), color(0.63, 0.75, 0.77), color(0.22, 0.39, 0.51)], CGPoint(x: 0, y: 400), CGPoint(x: 0, y: 1100))
        // Sun, with a subtle warm halo.
        let halo = CGGradient(colorsSpace: space, colors: [color(1, 0.86, 0.61, 0.55), color(1, 0.80, 0.55, 0)] as CFArray, locations: [0, 1])!
        cg.drawRadialGradient(halo, startCenter: CGPoint(x: 1180, y: 815), startRadius: 0,
                              endCenter: CGPoint(x: 1180, y: 815), endRadius: 240, options: [])
        cg.setFillColor(color(1, 0.91, 0.72)); cg.fillEllipse(in: CGRect(x: 1145, y: 780, width: 70, height: 70))
        polygon([CGPoint(x: 0,y: 390), CGPoint(x: 0,y: 600), CGPoint(x: 185,y: 815), CGPoint(x: 310,y: 700), CGPoint(x: 465,y: 975), CGPoint(x: 725,y: 650), CGPoint(x: 960,y: 880), CGPoint(x: 1200,y: 610), CGPoint(x: 1400,y: 815), CGPoint(x: 1600,y: 640), CGPoint(x: 1600,y: 390)], color(0.37, 0.46, 0.51))
        polygon([CGPoint(x: 330,y: 790), CGPoint(x: 465,y: 975), CGPoint(x: 595,y: 814), CGPoint(x: 500,y: 850), CGPoint(x: 465,y: 886), CGPoint(x: 410,y: 830)], color(0.89, 0.87, 0.77))
        polygon([CGPoint(x: 838,y: 760), CGPoint(x: 960,y: 880), CGPoint(x: 1085,y: 748), CGPoint(x: 983,y: 788), CGPoint(x: 952,y: 815), CGPoint(x: 912,y: 766)], color(0.78, 0.79, 0.73))
        polygon([CGPoint(x: 0,y: 330), CGPoint(x: 0,y: 650), CGPoint(x: 210,y: 475), CGPoint(x: 390,y: 580), CGPoint(x: 620,y: 400), CGPoint(x: 890,y: 590), CGPoint(x: 1130,y: 460), CGPoint(x: 1450,y: 680), CGPoint(x: 1600,y: 590), CGPoint(x: 1600,y: 330)], color(0.19, 0.32, 0.34))
        cg.saveGState(); cg.clip(to: CGRect(x: 0, y: 0, width: w, height: 405))
        gradient([color(0.12, 0.29, 0.33), color(0.41, 0.55, 0.53), color(0.76, 0.68, 0.48)], CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 410))
        // Reflected light and horizontal water ripples.
        for i in 0..<120 {
            let y = CGFloat(i) * 3.25 + 8
            let length = 30 + CGFloat((i * 67) % 330)
            let x = CGFloat((i * 193) % 1700) - 100
            cg.setStrokeColor(color(0.88, 0.79, 0.57, 0.04 + CGFloat(i % 4) * 0.025))
            cg.setLineWidth(1 + CGFloat(i % 3)); cg.move(to: CGPoint(x: x, y: y)); cg.addLine(to: CGPoint(x: x + length, y: y)); cg.strokePath()
        }
        cg.restoreGState()
        // Foreground shoreline and a small group of evergreen silhouettes.
        polygon([CGPoint(x: 0,y: 0), CGPoint(x: 0,y: 290), CGPoint(x: 180,y: 245), CGPoint(x: 390,y: 160), CGPoint(x: 610,y: 130), CGPoint(x: 800,y: 0)], color(0.08, 0.19, 0.20))
        polygon([CGPoint(x: 1250,y: 0), CGPoint(x: 1420,y: 130), CGPoint(x: 1600,y: 200), CGPoint(x: 1600,y: 0)], color(0.09, 0.19, 0.18))
        for (x, y, height) in [(95.0, 230.0, 250.0), (175.0, 220.0, 320.0), (245.0, 190.0, 220.0), (1415.0, 90.0, 200.0), (1490.0, 125.0, 260.0)] {
            cg.setFillColor(color(0.06, 0.16, 0.17)); cg.fill(CGRect(x: x - 4, y: y, width: 8, height: height * 0.85))
            for branch in 0..<5 {
                let bottom = y + height * (0.13 + Double(branch) * 0.14)
                let half = height * (0.25 - Double(branch) * 0.038)
                polygon([CGPoint(x: x - half,y: bottom), CGPoint(x: x,y: bottom + height * 0.40), CGPoint(x: x + half,y: bottom)], color(0.06, 0.16, 0.17))
            }
        }
        guard let image = cg.makeImage() else { throw ImagePipeline.PipelineError.renderFailed }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImagePipeline.PipelineError.exportFailed
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.97] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImagePipeline.PipelineError.exportFailed }
        return data as Data
    }
}
