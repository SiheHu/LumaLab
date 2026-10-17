import LumaDomain
import SwiftUI
import AppKit

struct PhotoCanvas: View {
    @ObservedObject var model: EditorModel
    @State private var referenceFitZoom:Double = 100
    @State private var dragMode = CanvasDragMode.none
    @State private var dragOrigin = UnitPoint2D.center
    @State private var initialCrop = CropRegion.full
    @State private var initialShape: MaskComponent?
    @State private var initialRepair:RepairStroke?
    @State private var dragActive = false
    @State private var changed = false

    var body: some View {
        GeometryReader { geometry in
            if let image = model.showBefore ? model.beforePreview : model.preview {
                if model.comparisonLayout == .single {
                    imageViewport(image, viewport: geometry.size)
                } else if model.comparisonLayout == .splitHorizontal {
                    VStack(spacing:1) {
                        comparisonPane(model.beforePreview ?? image,title:"编辑前",reference:false)
                        comparisonPane(model.preview ?? image,title:"当前效果",reference:false,interactive:true)
                    }
                } else {
                    HStack(spacing:1) {
                        comparisonPane(model.comparisonLayout == .reference ? (model.referencePreview ?? image):(model.beforePreview ?? image),title:model.comparisonLayout == .reference ? model.referenceName:"编辑前",reference:model.comparisonLayout == .reference)
                        comparisonPane(model.preview ?? image,title:"当前效果",reference:false,interactive:true)
                    }
                }
            } else {
                VStack(spacing: 13) {
                    ProgressView().controlSize(.small)
                    Text(L("正在准备照片…")).font(.system(size: 12)).foregroundStyle(Palette.muted)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.background)
        .onDisappear { model.isDrawingMask = false }
        .overlay(alignment: .top) {
            if model.sampleMode != .none && !model.showBefore { sampleGuide }
        }
    }

    private func comparisonPane(_ image:CGImage,title:String,reference:Bool,interactive:Bool=false)->some View {
        VStack(spacing:0) {
            Text(L(title)).font(.system(size:10)).foregroundStyle(Palette.muted).padding(6)
            GeometryReader {geo in imageViewport(image,viewport:geo.size,interactive:interactive,reference:reference)}
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
    }
    private func imageViewport(_ image: CGImage, viewport: CGSize, interactive:Bool=true, reference:Bool=false) -> some View {
        let backing = NSApp.keyWindow?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let nativeSize = reference ? model.referencePixelSize:model.previewPixelSize
        let pixels = nativeSize.width > 0 ? nativeSize : CGSize(width: image.width, height: image.height)
        let size = CGSize(width: pixels.width / backing, height: pixels.height / backing)
        return NativePhotoViewport(size: size, zoom: $model.zoom, fitZoom: reference ? $referenceFitZoom:$model.fitZoom, center:$model.viewportCenter, identity: model.documentID.uuidString + (reference ? "-reference":""), pointerEnabled: interactive && interactionEnabled, brushCursor: interactive ? brushCursor:nil, processing: interactive && model.isProcessingRepairs, onPointer: handlePointer) {
            ZStack {
                Rectangle().fill(ImagePaint(image:Image(decorative:TransparencyTile.image,scale:1),scale:1/guideScale)).allowsHitTesting(false)
                Image(decorative: image, scale: 1).resizable().interpolation(.high)
                if !model.showBefore && interactive {
                    if model.showClipping { ClippingWarningOverlay(image: image).allowsHitTesting(false) }
                    if model.tool == .crop {
                        CropGuide(crop: model.edits.crop, scale: guideScale).allowsHitTesting(false)
                        if model.showGeometryGuides {GeometryReferenceGrid(scale:guideScale).allowsHitTesting(false)}
                    }
                    if model.tool == .repair && model.showRepairHandles {
                        RepairGuide(strokes:model.edits.repairs,selected:model.selectedRepairID,draft:model.repairDraft,radius:model.repairRadius,scale:guideScale).allowsHitTesting(false)
                    }
                    if model.tool == .masks {
                        if let coverage=model.coverageImage,model.coveragePreviewEnabled {
                            Image(decorative:coverage,scale:1).resizable().interpolation(.high).allowsHitTesting(false)
                        } else if let overlay = model.maskOverlay {
                            Image(decorative: overlay, scale: 1).resizable().interpolation(.high).allowsHitTesting(false)
                        }
                        if model.selectedMaskHandlesVisible, let shape = model.activeShape {
                            MaskGeometryGuide(shape: shape, scale: guideScale).allowsHitTesting(false)
                        }
                    }
                } else if model.showBefore && interactive {
                    VStack {
                        HStack {
                            Text(L("编辑前")).font(.system(size: 10, weight: .medium)).padding(9)
                                .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                            Spacer()
                        }
                        Spacer()
                    }.padding(14).allowsHitTesting(false)
                }
            }
            .frame(width: size.width, height: size.height)
            .background(Color.black)
            .clipped()
            .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
            .contentShape(Rectangle())
        }
    }

    private var brushCursor: BrushCursorStyle? {
        guard interactionEnabled, !model.editingLocked, model.sampleMode == .none else { return nil }
        if model.tool == .repair, !model.isPickingRepairSource {
            let radius = min(0.45,max(0.001,model.selectedRepair?.radius ?? model.repairRadius))
            let feather = min(1,max(0,model.selectedRepair?.feather ?? model.repairFeather))
            let outward = (model.selectedRepair?.mode ?? model.repairMode) == .inpaint && (model.selectedRepair?.algorithmVersion ?? 3) >= 3
            let shortDimension = max(1,min(model.previewPixelSize.width,model.previewPixelSize.height))
            let extensionWidth = outward ? PortableHealing.inpaintingFeatherWidth(radius:radius * shortDimension,imageShortDimension:shortDimension,feather:feather) / shortDimension : 0
            return BrushCursorStyle(diameterFraction: (radius + extensionWidth) * 2, feather: feather,
                innerRadiusFraction: outward ? radius / (radius + extensionWidth) : nil)
        }
        if model.tool == .masks, let shape = model.activeShape, shape.kind == .brush {
            return BrushCursorStyle(diameterFraction: min(3,max(0.001,shape.brushSize)), feather: shape.feather)
        }
        return nil
    }
    private var interactionEnabled: Bool { !model.showBefore && (model.tool != .edit || model.sampleMode != .none) }
    private var sampleGuide: some View {
        HStack(spacing: 12) {
            Image(systemName: "eyedropper").foregroundStyle(Palette.accent)
            Text(L(model.sampleMode.instruction)).font(.system(size: 11))
            Button(L("取消")) { model.sampleMode = .none }.buttonStyle(.plain)
                .font(.system(size: 10)).foregroundStyle(Palette.muted).keyboardShortcut(.escape, modifiers: [])
        }.padding(.horizontal, 14).padding(.vertical, 10)
            .background(Palette.panel.opacity(0.96), in: Capsule())
            .overlay(Capsule().stroke(Palette.border, lineWidth: 1)).padding(.top, 12)
    }

    private var guideScale: CGFloat { max(0.0001,CGFloat((model.zoom == 1 ? model.fitZoom : model.zoom) / 100)) }
    private func handlePointer(_ event: CanvasPointerEvent) {
        guard interactionEnabled, !model.editingLocked else { return }
        let size = event.displaySize
        let location = CGPoint(x:event.point.x*size.width,y:event.point.y*size.height)
        switch event.phase {
        case .down:
            beginDrag(at:location,size:size)
            if model.tool == .masks {
                switch dragMode {
                case .brush, .maskNew, .maskHandle, .maskMove: model.isDrawingMask = true
                default: break
                }
            }
            updateDrag(at:location,size:size)
        case .dragged:
            guard dragActive else { return }; updateDrag(at:location,size:size)
        case .up:
            guard dragActive else { return }
            model.isDrawingMask = false
            if case .sample = dragMode { model.sample(at:event.point) }
            else if model.tool == .repair {
                if case .repairNew = dragMode {model.completeRepairStroke()}
                else if changed {model.commit();model.requestRender()}
            }
            else if changed {
                if case .maskNew = dragMode { model.pendingShapePlacement = false; model.status="选区已创建，可拖动控制点调整，或拖动内部移动" }
                model.commit(); model.requestRender()
            }
            dragMode = .none; dragActive = false; changed = false; initialShape = nil
        }
    }
    private func point(_ p: CGPoint, size: CGSize) -> UnitPoint2D {
        UnitPoint2D(x: min(1, max(0, p.x / max(size.width, 1))), y: min(1, max(0, p.y / max(size.height, 1))))
    }
    private func beginDrag(at location: CGPoint, size: CGSize) {
        dragActive = true; changed = false
        dragOrigin = point(location, size: size)
        if model.sampleMode != .none { dragMode = .sample; return }
        if model.tool == .repair {
            if model.isPickingRepairSource {
                model.repairManualSource=dragOrigin;model.repairAutoSample=false;model.isPickingRepairSource=false
                if model.selectedRepair != nil {model.updateRepair {$0.source=dragOrigin};model.commit()}
                dragMode = .none;return
            }
            if model.showRepairHandles,let selected=model.selectedRepair, selected.mode != .inpaint,
               nearest([selected.source],to:dragOrigin,size:size,tolerance:16) != nil {
                initialRepair=selected;dragMode = .repairSource;return
            }
            let hit=model.edits.repairs.reversed().first {stroke in
                stroke.enabled && stroke.points.contains {hypot(($0.x-dragOrigin.x)*size.width,($0.y-dragOrigin.y)*size.height)<max(12,stroke.radius*min(size.width,size.height))}
            }
            if model.showRepairHandles,let hit=hit {model.selectedRepairID=hit.id;initialRepair=hit;dragMode = .repairMove}
            else {
                if let selected = model.selectedRepair {
                    model.repairRadius = selected.radius; model.repairFeather = selected.feather
                    model.repairOpacity = selected.opacity; model.repairMode = selected.mode
                }
                model.selectedRepairID=nil;model.repairDraft=[dragOrigin];dragMode = .repairNew
            }
            return
        }
        if model.tool == .crop {
            initialCrop = model.edits.crop
            let corners = cropCorners(initialCrop)
            if let corner = nearest(corners, to: dragOrigin, size: size, tolerance: 16) {
                dragMode = .cropCorner(corner)
            } else if !initialCrop.isFull && contains(dragOrigin, crop: initialCrop) {
                dragMode = .cropMove
            } else { dragMode = .cropNew }
            return
        }
        guard model.tool == .masks, let shape = model.activeShape else { dragMode = .none; return }
        initialShape = shape
        if shape.kind == .brush {
            dragMode = .brush
            let p = dragOrigin
            let erase = model.brushErase
            model.updateActiveShape { current in
                if model.autoMaskBrush {
                    var stroke=EdgeBrushStroke();stroke.points=[p];stroke.color=model.source.map {model.renderer.sampledRGB(source:$0,point:p)} ?? [0,0,0]
                    stroke.tolerance=model.autoMaskTolerance;stroke.diameter=current.brushSize;stroke.feather=current.feather;stroke.erase=erase
                    current.edgeStrokes.append(stroke)
                } else if erase { current.erasedStrokes.append([p]) } else { current.strokes.append([p]) }
            }
            changed = true; model.requestRender()
        } else if shape.kind == .colorRange || shape.kind == .luminanceRange || shape.kind == .automatic {
            dragMode = .none
        } else if model.pendingShapePlacement {
            dragMode = .maskNew
        } else if model.selectedMaskHandlesVisible, let handle = nearest([shape.start, shape.end], to: dragOrigin, size: size, tolerance: 16) {
            dragMode = .maskHandle(handle)
        } else if model.selectedMaskHandlesVisible && shapeContains(dragOrigin, shape: shape, size: size) {
            dragMode = .maskMove
        } else { dragMode = .none }
    }
    private func updateDrag(at location: CGPoint, size: CGSize) {
        let p = point(location, size: size)
        let delta = UnitPoint2D(x: p.x - dragOrigin.x, y: p.y - dragOrigin.y)
        switch dragMode {
        case .repairNew:
            if let last=model.repairDraft.last,hypot((p.x-last.x)*size.width,(p.y-last.y)*size.height)>1 {model.repairDraft.append(p)};changed=true
        case .repairSource:
            guard let original=initialRepair else {return}
            model.updateRepair {$0.source=UnitPoint2D(x:min(1,max(0,original.source.x+delta.x)),y:min(1,max(0,original.source.y+delta.y)))};changed=true
        case .repairMove:
            guard let original=initialRepair else {return}
            model.updateRepair {$0=original.moved(dx:delta.x,dy:delta.y)};changed=true
        case .none, .sample: return
        case .cropMove:
            var crop = initialCrop
            crop.x = min(1 - crop.width, max(0, crop.x + delta.x))
            crop.y = min(1 - crop.height, max(0, crop.y + delta.y))
            model.edits.crop = crop; changed = true
        case .cropCorner(let corner):
            let anchor = cropCorners(initialCrop)[(corner + 2) % 4]
            model.edits.crop = resizedCrop(anchor: anchor, target: p, signX: (corner == 0 || corner == 3) ? -1 : 1, signY: corner < 2 ? -1 : 1, size: size)
            changed = true
        case .cropNew:
            guard hypot(delta.x * size.width, delta.y * size.height) > 2 else { return }
            model.edits.crop = resizedCrop(anchor: dragOrigin, target: p, signX: p.x >= dragOrigin.x ? 1 : -1, signY: p.y >= dragOrigin.y ? 1 : -1, size: size)
            changed = true
        case .brush:
            let erase = model.brushErase
            model.updateActiveShape { shape in
                if model.autoMaskBrush, !shape.edgeStrokes.isEmpty {
                    let i=shape.edgeStrokes.count-1
                    if let last=shape.edgeStrokes[i].points.last, hypot((last.x-p.x)*size.width,(last.y-p.y)*size.height)>1 {shape.edgeStrokes[i].points.append(p)}
                } else if erase { appendPoint(p, to: &shape.erasedStrokes, size: size) }
                else { appendPoint(p, to: &shape.strokes, size: size) }
            }
            changed = true; model.requestRender()
        case .maskMove:
            guard let original = initialShape else { return }
            let dx = min(1 - max(original.start.x, original.end.x), max(-min(original.start.x, original.end.x), delta.x))
            let dy = min(1 - max(original.start.y, original.end.y), max(-min(original.start.y, original.end.y), delta.y))
            model.updateActiveShape { shape in
                shape.start = UnitPoint2D(x: original.start.x + dx, y: original.start.y + dy)
                shape.end = UnitPoint2D(x: original.end.x + dx, y: original.end.y + dy)
            }
            changed = true; model.requestRender()
        case .maskHandle(let index):
            model.updateActiveShape { shape in if index == 0 { shape.start = p } else { shape.end = p } }
            changed = true; model.requestRender()
        case .maskNew:
            guard hypot(delta.x * size.width, delta.y * size.height) > 2 else { return }
            model.updateActiveShape { shape in shape.start = dragOrigin; shape.end = p }
            changed = true; model.requestRender()
        }
    }
    private func appendPoint(_ p: UnitPoint2D, to strokes: inout [[UnitPoint2D]], size: CGSize) {
        guard let index = strokes.indices.last else { return }
        if let last = strokes[index].last, hypot((last.x - p.x) * size.width, (last.y - p.y) * size.height) < 1 { return }
        strokes[index].append(p)
    }
    private func resizedCrop(anchor: UnitPoint2D, target: UnitPoint2D, signX: Double, signY: Double, size: CGSize) -> CropRegion {
        var width = max(0.005, (target.x - anchor.x) * signX)
        var height = max(0.005, (target.y - anchor.y) * signY)
        let maxWidth = signX > 0 ? 1 - anchor.x : anchor.x
        let maxHeight = signY > 0 ? 1 - anchor.y : anchor.y
        if let ratio = model.cropAspect, ratio > 0 {
            let normalized = ratio / max(size.width / max(size.height, 1), 0.0001)
            if width / height > normalized { height = width / normalized } else { width = height * normalized }
            let bound = min(1, min(maxWidth / max(width, 0.0001), maxHeight / max(height, 0.0001)))
            width *= bound; height *= bound
        } else {
            width = min(width, maxWidth); height = min(height, maxHeight)
        }
        let finalWidth = min(1, max(width, 0.001)), finalHeight = min(1, max(height, 0.001))
        let x = signX > 0 ? anchor.x : anchor.x - finalWidth
        let y = signY > 0 ? anchor.y : anchor.y - finalHeight
        return CropRegion(x: min(1 - finalWidth, max(0, x)), y: min(1 - finalHeight, max(0, y)), width: finalWidth, height: finalHeight)
    }
    private func cropCorners(_ crop: CropRegion) -> [UnitPoint2D] {
        [UnitPoint2D(x: crop.x, y: crop.y), UnitPoint2D(x: crop.x + crop.width, y: crop.y), UnitPoint2D(x: crop.x + crop.width, y: crop.y + crop.height), UnitPoint2D(x: crop.x, y: crop.y + crop.height)]
    }
    private func contains(_ point: UnitPoint2D, crop: CropRegion) -> Bool {
        point.x >= crop.x && point.x <= crop.x + crop.width && point.y >= crop.y && point.y <= crop.y + crop.height
    }
    private func nearest(_ points: [UnitPoint2D], to p: UnitPoint2D, size: CGSize, tolerance: Double) -> Int? {
        points.indices.min(by: { hypot((points[$0].x - p.x) * size.width, (points[$0].y - p.y) * size.height) < hypot((points[$1].x - p.x) * size.width, (points[$1].y - p.y) * size.height) }).flatMap { index in
            hypot((points[index].x - p.x) * size.width, (points[index].y - p.y) * size.height) <= tolerance ? index : nil
        }
    }
    private func shapeContains(_ p: UnitPoint2D, shape: MaskComponent, size: CGSize) -> Bool {
        let lowX = min(shape.start.x, shape.end.x), highX = max(shape.start.x, shape.end.x)
        let lowY = min(shape.start.y, shape.end.y), highY = max(shape.start.y, shape.end.y)
        if shape.kind == .rectangle { return p.x >= lowX && p.x <= highX && p.y >= lowY && p.y <= highY }
        if shape.kind == .radial {
            let x = (p.x - (lowX + highX) / 2) / max((highX - lowX) / 2, 0.0001)
            let y = (p.y - (lowY + highY) / 2) / max((highY - lowY) / 2, 0.0001)
            return x * x + y * y <= 1
        }
        let ax = shape.start.x * size.width, ay = shape.start.y * size.height
        let bx = shape.end.x * size.width, by = shape.end.y * size.height
        let px = p.x * size.width, py = p.y * size.height
        let t = min(1, max(0, ((px - ax) * (bx - ax) + (py - ay) * (by - ay)) / max(pow(bx - ax, 2) + pow(by - ay, 2), 0.001)))
        return hypot(px - ax - t * (bx - ax), py - ay - t * (by - ay)) < 10
    }
}

private enum CanvasDragMode {
    case repairNew, repairSource, repairMove
    case none, sample, cropMove, cropCorner(Int), cropNew, brush, maskMove, maskHandle(Int), maskNew
}

private struct CropGuide: View {
    var crop: CropRegion
    var scale: CGFloat
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(x: crop.x * size.width, y: crop.y * size.height, width: crop.width * size.width, height: crop.height * size.height)
            var outside = Path(CGRect(origin: .zero, size: size)); outside.addRect(rect)
            context.fill(outside, with: .color(.black.opacity(0.57)), style: .init(eoFill: true))
            context.stroke(Path(rect), with: .color(.white.opacity(0.95)), lineWidth: 1 / scale)
            for i in 1...2 {
                var grid = Path()
                let x = rect.minX + rect.width * CGFloat(i) / 3, y = rect.minY + rect.height * CGFloat(i) / 3
                grid.move(to: .init(x: x, y: rect.minY)); grid.addLine(to: .init(x: x, y: rect.maxY))
                grid.move(to: .init(x: rect.minX, y: y)); grid.addLine(to: .init(x: rect.maxX, y: y))
                context.stroke(grid, with: .color(.white.opacity(0.3)), lineWidth: 0.6 / scale)
            }
            for p in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)] {
                context.fill(Path(CGRect(x: p.x - 4 / scale, y: p.y - 4 / scale, width: 8 / scale, height: 8 / scale)), with: .color(Palette.accent))
            }
        }.accessibilityLabel(L("可拖动的裁剪边框与角点"))
    }
}

private struct MaskGeometryGuide: View {
    let shape: MaskComponent
    var scale: CGFloat
    var body: some View {
        Canvas { context, size in
            guard shape.kind == .linear || shape.kind == .radial || shape.kind == .rectangle else { return }
            let start = CGPoint(x: shape.start.x * size.width, y: shape.start.y * size.height)
            let end = CGPoint(x: shape.end.x * size.width, y: shape.end.y * size.height)
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            var outline = Path()
            if shape.kind == .radial { outline.addEllipse(in: rect) }
            else if shape.kind == .rectangle { outline.addRect(rect) }
            else { outline.move(to: start); outline.addLine(to: end) }
            context.stroke(outline, with: .color(.white.opacity(0.85)), style: .init(lineWidth: 1 / scale, dash: [5 / scale, 4 / scale]))
            for p in [start, end] {
                let circle = Path(ellipseIn: CGRect(x: p.x - 4 / scale, y: p.y - 4 / scale, width: 8 / scale, height: 8 / scale))
                context.fill(circle, with: .color(Palette.background))
                context.stroke(circle, with: .color(.white), lineWidth: 1.2 / scale)
            }
        }.accessibilityLabel(L("选区形状控制点"))
    }
}

private struct ClippingWarningOverlay: View {
    let image: CGImage
    @State private var overlay: CGImage?
    var body: some View {
        Group {
            if let overlay = overlay { Image(decorative: overlay, scale: 1).resizable().interpolation(.none) }
        }.task(id: ObjectIdentifier(image)) {
            let next = await Self.makeOverlay(image)
            if !Task.isCancelled { overlay = next }
        }.accessibilityLabel(L("红色标记高光溢出，蓝色标记阴影溢出"))
    }
    private static func makeOverlay(_ image: CGImage) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 100_000, height <= 100_000, width <= Int.max / height / 4 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let flags = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: flags) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
        }
        guard drawn else { return nil }
        for y in 0..<height {
            if Task.isCancelled { return nil }
            for x in 0..<width {
                let i = (y * width + x) * 4
                let alpha = Int(pixels[i + 3])
                guard alpha > 0 else { continue }
                let r = Int(pixels[i]) * 255 / alpha, g = Int(pixels[i + 1]) * 255 / alpha, b = Int(pixels[i + 2]) * 255 / alpha
                if max(r, max(g, b)) >= 254 {
                    pixels[i] = 185; pixels[i + 1] = 28; pixels[i + 2] = 24; pixels[i + 3] = 185
                } else if max(r, max(g, b)) <= 1 {
                    pixels[i] = 20; pixels[i + 1] = 65; pixels[i + 2] = 185; pixels[i + 3] = 185
                } else { pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 0 }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: flags), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}


private enum TransparencyTile {
    static let image: CGImage = {
        let w=16
        var bytes=[UInt8](repeating:255,count:w*w*4)
        for y in 0..<w {for x in 0..<w {
            let gray:UInt8=((x/8+y/8)%2==0) ? 42:57
            let i=(y*w+x)*4;bytes[i]=gray;bytes[i+1]=gray;bytes[i+2]=gray
        }}
        return CGImage(width:w,height:w,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,
                       space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider:CGDataProvider(data:Data(bytes) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
    }()
}

private struct GeometryReferenceGrid: View {
    var scale:CGFloat
    var body:some View {
        Canvas {context,size in
            for i in 1..<12 {
                var path=Path()
                let x=CGFloat(i)/12*size.width,y=CGFloat(i)/12*size.height
                path.move(to:CGPoint(x:x,y:0));path.addLine(to:CGPoint(x:x,y:size.height))
                path.move(to:CGPoint(x:0,y:y));path.addLine(to:CGPoint(x:size.width,y:y))
                context.stroke(path,with:.color(.black.opacity(0.35)),lineWidth:2/scale)
                context.stroke(path,with:.color(.white.opacity(i==6 ? 0.65:0.3)),lineWidth:0.7/scale)
            }
        }.accessibilityLabel(L("旋转与透视参考线"))
    }
}
