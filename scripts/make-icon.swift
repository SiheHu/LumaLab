import AppKit

// Original LumaLab artwork; no third-party assets or Adobe marks.
let destination = CommandLine.arguments.dropFirst().first ?? "LumaLab.png"
let dimension = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: dimension, pixelsHigh: dimension, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: dimension, height: dimension).fill()
let tile = NSBezierPath(roundedRect: NSRect(x: 68, y: 68, width: 888, height: 888), xRadius: 196, yRadius: 196)
NSGradient(starting: NSColor(calibratedRed: 0.15, green: 0.24, blue: 0.32, alpha: 1), ending: NSColor(calibratedRed: 0.045, green: 0.075, blue: 0.11, alpha: 1))!.draw(in: tile, angle: -70)
NSGraphicsContext.saveGraphicsState()
tile.addClip()
let hill = NSBezierPath()
hill.move(to: NSPoint(x: 0, y: 110))
hill.curve(to: NSPoint(x: 1100, y: 310), controlPoint1: NSPoint(x: 370, y: 510), controlPoint2: NSPoint(x: 640, y: 80))
hill.line(to: NSPoint(x: 1100, y: 0))
hill.line(to: .zero)
hill.close()
NSColor(calibratedRed: 0.22, green: 0.43, blue: 0.45, alpha: 1).setFill()
hill.fill()
let frontHill = NSBezierPath()
frontHill.move(to: NSPoint(x: 0, y: 0))
frontHill.line(to: NSPoint(x: 0, y: 230))
frontHill.curve(to: NSPoint(x: 1100, y: 100), controlPoint1: NSPoint(x: 380, y: -60), controlPoint2: NSPoint(x: 680, y: 400))
frontHill.line(to: NSPoint(x: 1100, y: 0))
frontHill.close()
NSColor(calibratedRed: 0.11, green: 0.27, blue: 0.30, alpha: 1).setFill()
frontHill.fill()
NSGraphicsContext.restoreGraphicsState()
let ring = NSBezierPath(ovalIn: NSRect(x: 270, y: 330, width: 484, height: 484))
ring.lineWidth = 42
NSColor(calibratedRed: 0.93, green: 0.78, blue: 0.49, alpha: 1).setStroke()
ring.stroke()
let sun = NSBezierPath(ovalIn: NSRect(x: 402, y: 462, width: 220, height: 220))
NSColor(calibratedRed: 1, green: 0.87, blue: 0.58, alpha: 1).setFill()
sun.fill()
let glint = NSBezierPath(roundedRect: NSRect(x: 771, y: 737, width: 40, height: 104), xRadius: 20, yRadius: 20)
NSColor(calibratedRed: 0.93, green: 0.78, blue: 0.49, alpha: 1).setFill()
glint.fill()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))

// Encode PNG-backed ICNS directly. This also works when a host's iconutil cannot
// consume iconsets produced using an older SDK.
if CommandLine.arguments.count > 2 {
    let image = NSImage(size: NSSize(width: dimension, height: dimension))
    image.addRepresentation(bitmap)
    func lengthData(_ value: Int) -> Data {
        var length = UInt32(value).bigEndian
        return withUnsafeBytes(of: &length) { Data($0) }
    }
    var chunks = Data()
    for (size, type) in [(128, "ic07"), (256, "ic08"), (512, "ic09"), (1024, "ic10")] {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: NSRect(x: 0, y: 0, width: dimension, height: dimension), operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let png = rep.representation(using: .png, properties: [:])!
        chunks.append(type.data(using: .ascii)!)
        chunks.append(lengthData(png.count + 8))
        chunks.append(png)
    }
    var file = Data("icns".utf8)
    file.append(lengthData(chunks.count + 8))
    file.append(chunks)
    try file.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
