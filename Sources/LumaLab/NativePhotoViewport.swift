import LumaDomain
import AppKit
import SwiftUI

enum ViewportGeometry {
    static func fitScale(image: CGSize, viewport: CGSize) -> CGFloat {
        min(8, max(0.0001, min(max(1, viewport.width - 54) / max(1, image.width),
                              max(1, viewport.height - 54) / max(1, image.height))))
    }
    static func normalizedPoint(_ point: CGPoint, in bounds: CGRect, flipped: Bool) -> UnitPoint2D {
        let x = (point.x - bounds.minX) / max(1,bounds.width)
        let y = (point.y - bounds.minY) / max(1,bounds.height)
        return UnitPoint2D(x:min(1,max(0,x)),y:min(1,max(0,flipped ? y : 1-y)))
    }
}

struct BrushCursorStyle: Equatable {
    var diameterFraction: Double
    var feather: Double
    var innerRadiusFraction: Double? = nil
}

struct CanvasPointerEvent {
    enum Phase { case down, dragged, up }
    var phase: Phase
    var point: UnitPoint2D
    var displaySize: CGSize
}

/// AppKit owns magnification and scrolling so a trackpad gesture stays anchored
/// under the pointer, including while the proxy is replaced by a detailed image.
struct NativePhotoViewport<Content: View>: NSViewRepresentable {
    var size: CGSize
    @Binding var zoom: Double
    @Binding var fitZoom: Double
    @Binding var center: UnitPoint2D
    var identity: String
    var pointerEnabled: Bool
    var brushCursor: BrushCursorStyle? = nil
    var processing = false
    var onPointer: (CanvasPointerEvent) -> Void
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PhotoScrollView {
        let scroll = PhotoScrollView()
        scroll.contentView = CenteredPhotoClipView()
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.0001
        scroll.maxMagnification = 8
        scroll.automaticallyAdjustsContentInsets = false
        let host = PhotoHostingView(rootView: AnyView(Color.clear))
        host.sizingOptions = []
        scroll.documentView = host
        context.coordinator.host = host
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.boundsObserver = NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:scroll.contentView,queue:.main) { [weak coordinator=context.coordinator,weak scroll] _ in
            if let scroll {coordinator?.reportCenter(scroll.contentView.bounds)}
        }
        scroll.onMagnification = { [weak coordinator = context.coordinator] in coordinator?.reportZoom($0) }
        scroll.onLayout = { [weak coordinator = context.coordinator, weak scroll] in
            DispatchQueue.main.async { if let scroll = scroll { coordinator?.apply(to: scroll) } }
        }
        return scroll
    }

    func updateNSView(_ scroll: PhotoScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.centerBinding = $center
        coordinator.requestedCenter = center
        coordinator.zoomBinding = $zoom
        coordinator.fitBinding = $fitZoom
        coordinator.requestedZoom = zoom
        coordinator.newIdentity = identity
        coordinator.imageSize = size
        coordinator.host?.pointerEnabled = pointerEnabled
        coordinator.host?.onPointer = onPointer
        coordinator.host?.processing = processing
        coordinator.host?.brushCursor = brushCursor
        coordinator.host?.rootView = AnyView(content().frame(width: size.width, height: size.height))
        coordinator.apply(to: scroll)
    }

    final class Coordinator {
        var host: PhotoHostingView?
        var centerBinding: Binding<UnitPoint2D>?
        var requestedCenter = UnitPoint2D.center
        var lastCenter = UnitPoint2D.center
        var zoomBinding: Binding<Double>?
        var fitBinding: Binding<Double>?
        var requestedZoom = 1.0
        var lastZoom: Double?
        var imageSize = CGSize.zero
        var documentSize = CGSize.zero
        var newIdentity = ""
        var identity: String?
        var fitScale: CGFloat = 1
        var applying = false

        func reportCenter(_ bounds:CGRect) {
            guard !applying,documentSize.width>0,documentSize.height>0 else {return}
            let value=UnitPoint2D(x:min(1,max(0,bounds.midX/documentSize.width)),y:min(1,max(0,bounds.midY/documentSize.height)))
            guard abs(value.x-lastCenter.x)>0.00001 || abs(value.y-lastCenter.y)>0.00001 else {return}
            lastCenter=value;requestedCenter=value;centerBinding?.wrappedValue=value
        }
        func reportZoom(_ scale: CGFloat) {
            guard !applying else { return }
            let value = abs(scale - fitScale) < 0.00001 ? 1 : Double(scale) * 100
            requestedZoom = value; lastZoom = value
            zoomBinding?.wrappedValue = value
        }

        func apply(to scroll: PhotoScrollView) {
            guard !applying, let host = host, imageSize.width > 0, imageSize.height > 0,
                  scroll.contentSize.width > 0, scroll.contentSize.height > 0 else { return }
            applying = true; defer { applying = false }
            let newSize = imageSize
            let oldBounds = scroll.contentView.bounds
            let oldCenter = CGPoint(x: oldBounds.midX, y: oldBounds.midY)
            let center = CGPoint(x: documentSize.width > 0 ? oldCenter.x / documentSize.width * newSize.width : newSize.width / 2,
                                 y: documentSize.height > 0 ? oldCenter.y / documentSize.height * newSize.height : newSize.height / 2)
            let changedDocument = documentSize != newSize || identity != newIdentity
            let changedIdentity = identity != newIdentity
            if documentSize != newSize { host.setFrameSize(newSize); documentSize = newSize }
            identity = newIdentity
            fitScale = ViewportGeometry.fitScale(image: imageSize, viewport: scroll.contentSize)
            scroll.fitScale = fitScale
            scroll.minMagnification = min(0.02, fitScale)
            let percent = Double(fitScale) * 100
            if let binding = fitBinding, abs(binding.wrappedValue - percent) > 0.01 {
                DispatchQueue.main.async { binding.wrappedValue = percent }
            }
            let target = requestedZoom == 1 ? fitScale : min(8, max(scroll.minMagnification, CGFloat(requestedZoom / 100)))
            if lastZoom != requestedZoom || changedDocument || (requestedZoom == 1 && abs(scroll.magnification - target) > 0.00001) {
                let anchor = changedIdentity ? CGPoint(x: newSize.width / 2, y: newSize.height / 2) : center
                scroll.setMagnification(target, centeredAt: anchor)
                if changedIdentity || requestedZoom == 1 {
                    let visible = scroll.contentView.bounds.size
                    scroll.contentView.scroll(to: CGPoint(x: (newSize.width - visible.width) / 2,
                                                         y: (newSize.height - visible.height) / 2))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                lastZoom = requestedZoom
            }
            if requestedZoom != 1 && (abs(requestedCenter.x-lastCenter.x)>0.00001 || abs(requestedCenter.y-lastCenter.y)>0.00001) {
                let visible=scroll.contentView.bounds.size
                scroll.contentView.scroll(to:CGPoint(x:requestedCenter.x*newSize.width-visible.width/2,y:requestedCenter.y*newSize.height-visible.height/2))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            lastCenter=requestedCenter
        }
    }
}

/// Native event conversion uses the actual document bounds after AppKit applies
/// scroll, centering, Retina scale and magnification. SwiftUI local gesture
/// coordinates inside a magnified NSHostingView are intentionally not used.
final class PhotoHostingView: NSHostingView<AnyView> {
    var pointerEnabled = false
    var onPointer: ((CanvasPointerEvent) -> Void)?
    private var pointerTracking: NSTrackingArea?
    private var lastPointerLocation: CGPoint?
    var brushCursor: BrushCursorStyle? {
        didSet {
            refreshBrushCursor()
            if brushCursor == nil, oldValue != nil, !processing { NSCursor.arrow.set() }
            window?.invalidateCursorRects(for: self)
        }
    }
    var processing = false {
        didSet {
            guard oldValue != processing else { return }
            refreshBrushCursor()
            if !processing && brushCursor == nil { NSCursor.arrow.set() }
            window?.invalidateCursorRects(for: self)
        }
    }
    private static let emptyCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        return NSCursor(image: image, hotSpot: .zero)
    }()
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = pointerTracking { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(area); pointerTracking = area
        refreshBrushCursor()
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if brushCursor != nil || processing { addCursorRect(visibleRect, cursor: Self.emptyCursor) }
    }
    override func cursorUpdate(with event: NSEvent) {
        if brushCursor != nil || processing { Self.emptyCursor.set() } else { NSCursor.arrow.set() }
    }
    override func mouseMoved(with event: NSEvent) { refreshBrushCursor(at: event.locationInWindow) }
    override func mouseEntered(with event: NSEvent) { refreshBrushCursor(at: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) {
        lastPointerLocation = nil
        (enclosingScrollView as? PhotoScrollView)?.hideBrushCursor()
        NSCursor.arrow.set()
    }
    private func refreshBrushCursor(at windowPoint: CGPoint? = nil) {
        if let point = windowPoint { lastPointerLocation = point }
        guard let scroll = enclosingScrollView as? PhotoScrollView else { return }
        guard brushCursor != nil || processing, let window = window, window.isKeyWindow,
              !isHidden, let point = lastPointerLocation else { scroll.hideBrushCursor(); return }
        let local = convert(point, from: nil)
        guard visibleRect.contains(local) else { scroll.hideBrushCursor(); return }
        scroll.showBrushCursor(at: point, style: brushCursor, processing: processing,
            radius: CGFloat(brushCursor?.diameterFraction ?? 0) * min(bounds.width, bounds.height) * scroll.magnification / 2)
        Self.emptyCursor.set()
    }
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(convert(point,from:superview)) else { return nil }
        return self
    }
    private func deliver(_ event: NSEvent, phase: CanvasPointerEvent.Phase) {
        guard pointerEnabled else { return }
        let local = convert(event.locationInWindow,from:nil)
        let point = ViewportGeometry.normalizedPoint(local,in:bounds,flipped:isFlipped)
        refreshBrushCursor(at: event.locationInWindow)
        let scale = enclosingScrollView?.magnification ?? 1
        onPointer?(CanvasPointerEvent(phase:phase,point:point,displaySize:CGSize(width:bounds.width*scale,height:bounds.height*scale)))
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); deliver(event,phase:.down) }
    override func mouseDragged(with event: NSEvent) { deliver(event,phase:.dragged) }
    override func mouseUp(with event: NSEvent) { deliver(event,phase:.up) }
    override func scrollWheel(with event: NSEvent) { enclosingScrollView?.scrollWheel(with:event) }
    override func magnify(with event: NSEvent) { enclosingScrollView?.magnify(with:event) }
    override func smartMagnify(with event: NSEvent) { enclosingScrollView?.smartMagnify(with:event) }
}

final class PhotoScrollView: NSScrollView {
    var boundsObserver:NSObjectProtocol?
    deinit {if let boundsObserver {NotificationCenter.default.removeObserver(boundsObserver)}}
    var onMagnification: ((CGFloat) -> Void)?
    var onLayout: (() -> Void)?
    var fitScale: CGFloat = 1
    private lazy var brushOverlay: BrushCursorOverlay = {
        let overlay = BrushCursorOverlay(frame: bounds)
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay, positioned: .above, relativeTo: nil)
        return overlay
    }()

    fileprivate func hideBrushCursor() { brushOverlay.position = nil; brushOverlay.processing = false }
    fileprivate func showBrushCursor(at windowPoint: CGPoint, style: BrushCursorStyle?, processing: Bool, radius: CGFloat) {
        // Keep this overlay outside NSHostingView's SwiftUI-managed subviews and
        // draw in viewport points, independent of document origin/magnification.
        let overlay = brushOverlay
        overlay.position = nil
        overlay.frame = bounds
        overlay.style = style ?? BrushCursorStyle(diameterFraction: 0, feather: 0)
        overlay.processing = processing
        overlay.zoom = 1
        overlay.radius = radius
        overlay.position = overlay.convert(windowPoint, from: nil)
    }

    override func layout() { super.layout(); onLayout?() }
    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        onMagnification?(magnification)
    }
    override func smartMagnify(with event: NSEvent) {
        guard let document = documentView else { return }
        let target = magnification > fitScale * 1.05 ? fitScale : min(maxMagnification, max(1, fitScale * 2))
        setMagnification(target, centeredAt: document.convert(event.locationInWindow, from: nil))
        onMagnification?(magnification)
    }
}

private final class CenteredPhotoClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var result = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return result }
        if document.frame.width < result.width { result.origin.x = (document.frame.width - result.width) / 2 }
        if document.frame.height < result.height { result.origin.y = (document.frame.height - result.height) / 2 }
        return result
    }
}

/// Native overlay keeps pointer movement independent of SwiftUI state and render jobs.
/// Its ring geometry shares the finite radius/feather convention of LumaCore.
private final class BrushCursorOverlay: NSView {
    var style = BrushCursorStyle(diameterFraction: 0.07, feather: 0.75)
    var zoom: CGFloat = 1
    var radius: CGFloat = 10
    var position: CGPoint? {
        willSet { if let point = position { setNeedsDisplay(damage(point)) } }
        didSet { if let point = position { setNeedsDisplay(damage(point)) } }
    }
    private var timer: Timer?
    private var angle: CGFloat = 0
    var processing = false {
        didSet {
            guard processing != oldValue else { return }
            timer?.invalidate(); timer = nil
            if processing {
                let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                    guard let self, let p = self.position else { return }
                    self.angle += .pi / 12
                    self.setNeedsDisplay(self.damage(p))
                }
                self.timer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
            if let p = position { setNeedsDisplay(damage(p)) }
        }
    }
    deinit { timer?.invalidate() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { processing = false }
    }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private func damage(_ p: CGPoint) -> CGRect {
        let r = max(radius, processing ? 10 : 0) + 4 / max(0.0001, zoom)
        return CGRect(x: p.x-r, y: p.y-r, width: r*2, height: r*2)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let p = position, let cg = NSGraphicsContext.current?.cgContext else { return }
        let scale = max(0.0001, zoom)
        func ring(_ r: CGFloat, dashed: Bool) {
            guard r * scale >= 2 else { return }
            let rect = CGRect(x: p.x-r, y: p.y-r, width: r*2, height: r*2)
            cg.setLineDash(phase: 0, lengths: dashed ? [3/scale, 3/scale] : [])
            cg.setLineWidth(3/scale); cg.setStrokeColor(NSColor.black.withAlphaComponent(0.85).cgColor); cg.strokeEllipse(in: rect)
            cg.setLineWidth(1/scale); cg.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor); cg.strokeEllipse(in: rect)
        }
        if processing {
            cg.setLineDash(phase: 0, lengths: [])
            let r: CGFloat = 8 / scale
            let rect = CGRect(x: p.x-r, y: p.y-r, width: r*2, height: r*2)
            cg.setLineWidth(4 / scale)
            cg.setStrokeColor(NSColor.black.withAlphaComponent(0.75).cgColor)
            cg.strokeEllipse(in: rect)
            cg.setLineWidth(2 / scale)
            cg.setStrokeColor(NSColor(calibratedRed: 0.77, green: 0.88, blue: 0.50, alpha: 1).cgColor)
            cg.addArc(center: p, radius: r, startAngle: angle, endAngle: angle + .pi * 1.5, clockwise: false)
            cg.strokePath()
        } else {
            ring(radius, dashed: false)
            if style.feather > 0.02 { ring(radius * CGFloat(style.innerRadiusFraction ?? (1 - min(1,max(0,style.feather)))), dashed: true) }
        }
    }
}
