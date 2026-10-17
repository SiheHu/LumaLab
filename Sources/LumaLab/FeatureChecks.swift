import Foundation
import CoreImage
import CoreGraphics
import LumaDomain

@MainActor enum FeatureChecks {
    struct Failure:LocalizedError {let message:String;var errorDescription:String? {message}}
    static func run() throws -> String {
        var count=0
        func check(_ value:Bool,_ message:String) throws {guard value else {throw Failure(message:message)};count+=1}
        let identity=CurveSpline(CurveSettings.line)
        try check((0...256).allSatisfy {abs(identity.value(at:Double($0)/256)-Double($0)/256)<0.000001},"Neutral cubic curve remains an exact identity")
        let points=[UnitPoint2D(x:0,y:0),UnitPoint2D(x:0.2,y:0.2),UnitPoint2D(x:0.4,y:0.55),UnitPoint2D(x:0.6,y:0.6),UnitPoint2D(x:0.8,y:0.8),UnitPoint2D(x:1,y:1)]
        let spline=CurveSpline(points)
        try check(points.allSatisfy{abs(spline.value(at:$0.x)-$0.y)<0.000001},"Cubic curve passes through every control point")
        let step=0.00001
        let left=(spline.value(at:0.4)-spline.value(at:0.4-step))/step
        let right=(spline.value(at:0.4+step)-spline.value(at:0.4))/step
        try check(abs(left-right)<0.002,"Cubic curve is tangent-continuous at control points")
        try check(abs(spline.value(at:0.9)-0.9)<0.000001,"Moving a midtone point leaves distant highlights unchanged")
        try check(abs(spline.value(at:0.3)-0.375)>0.001,"Curve uses smooth interpolation rather than a straight segment")
        let samples=(0...1000).map{spline.value(at:Double($0)/1000)}
        try check(zip(samples,samples.dropFirst()).allSatisfy{$0<=$1},"Monotone input points cannot create spline overshoot or reversals")
        try check(PortableSegmentation.faceLabels(for:.face).contains(6),"Whole-face selection includes glasses instead of lens-shaped holes")
        try check(PortableSegmentation.faceLabels(for:.glasses)==[6],"Glasses have their own semantic selection")
        let w=8,h=8,plane=w*h
        var logits=[Float](repeating:0,count:plane*19)
        for i in 0..<plane {logits[6*plane+i]=10}
        let polygon=[UnitPoint2D(x:0.25,y:0.25),UnitPoint2D(x:0.75,y:0.25),UnitPoint2D(x:0.75,y:0.75),UnitPoint2D(x:0.25,y:0.75)]
        let eyes=try PortableSegmentation.eyeCoverage(logits:logits,width:w,height:h,polygons:[polygon])
        try check(eyes[4*w+4]==255 && eyes[0]==0,"Landmark-assisted eyes include lens interiors only near the eyes")
        for i in 0..<plane {logits[i]=20}
        let empty=try PortableSegmentation.eyeCoverage(logits:logits,width:w,height:h,polygons:[polygon])
        try check(empty.allSatisfy{$0==0},"Eye assistance never selects background merely inside a face landmark")
        let legacy=try JSONDecoder().decode(LocalMask.self,from:Data("{\"name\":\"legacy\",\"kind\":\"brush\"}".utf8))
        try check(legacy.hsl==HSLBand.defaults,"Legacy masks receive neutral local HSL")
        let engine=ImagePipeline()
        let source=CIImage(color:CIColor(red:0.8,green:0.2,blue:0.1)).cropped(to:CGRect(x:0,y:0,width:160,height:80))
        var mask=LocalMask(name:"local hsl",kind:.automatic)
        mask.raster=try PortableMaskRaster(width:2,height:1,pixels:Data([255,0]),modelID:"hsl-fixture")
        mask.hsl[0].hue=80
        var edits=EditState();edits.masks=[mask]
        func pixel(_ image:CGImage,_ x:Int,_ y:Int)->[UInt8] {
            let raw=[UInt8](image.dataProvider!.data! as Data),offset=y*image.bytesPerRow+x*4
            return Array(raw[offset..<(offset+4)])
        }
        let neutral=try engine.render(source:source,edits:.init())
        let adjusted=try engine.render(source:source,edits:edits)
        let selected=pixel(adjusted,10,40),reference=pixel(neutral,10,40)
        let difference=(0..<3).reduce(0){$0+abs(Int(selected[$1])-Int(reference[$1]))}
        try check(difference>15,"Local HSL works without any local basic adjustment")
        try check(pixel(adjusted,150,40)==pixel(neutral,150,40),"Local HSL does not affect pixels outside the mask")
        edits.masks[0].disabledSections.insert(.hsl)
        try check(pixel(try engine.render(source:source,edits:edits),10,40)==reference,"Local HSL eye disables only its group")
        try check(edits.renderingState.masks[0].hsl==HSLBand.defaults && edits.masks[0].hsl[0].hue==80,"Visibility preserves stored local HSL values")
        try check(try JSONDecoder().decode(EditState.self,from:JSONEncoder().encode(edits))==edits,"Local HSL and group visibility persist together")
        let model=EditorModel(loadWorkspace:false);model.edits=edits;model.selectedMaskID=mask.id
        model.edits.hsl[0].hue=23;model.edits.masks[0].hsl[1].saturation=40
        model.resetHSLBand(0,local:true)
        try check(model.edits.masks[0].hsl[0].hue==0 && model.edits.masks[0].hsl[1].saturation==40 && model.edits.hsl[0].hue==23,"Reset local HSL group preserves other bands and global HSL")
        model.resetSection(.hsl,local:true)
        try check(model.edits.masks[0].hsl==HSLBand.defaults && model.edits.hsl[0].hue==23,"Reset all local HSL never resets global HSL")
        try check(legacy.overlayVisible && legacy.handlesVisible, "Legacy masks default to visible overlays and handles")
        var second = LocalMask(name: "second", kind: .automatic)
        second.raster = try PortableMaskRaster(width: 2, height: 1, pixels: Data([0,255]), modelID: "overlay-fixture")
        model.edits.masks = [mask, second]; model.selectedMaskID = mask.id
        model.setMaskOverlayVisible(mask.id,false)
        try check(model.showOverlay && !model.edits.masks[0].overlayVisible && model.edits.masks[1].overlayVisible, "Overlay toggle changes only the selected mask")
        try check(model.overlayMasks.count == 1 && model.overlayMasks[0].mask.id == second.id && model.overlayMasks[0].alpha == 0.16, "Unselected opted-in masks remain faintly visible")
        model.isDrawingMask = true
        try check(model.overlayMasks.count == 2 && !model.edits.masks[0].overlayVisible, "Drawing temporarily shows the current mask without changing its saved toggle")
        let overlay = try engine.selectionOverlays(model.overlayMasks, source: source)
        let activeAlpha = Int(pixel(overlay,10,40)[3]), inactiveAlpha = Int(pixel(overlay,150,40)[3])
        try check(activeAlpha > 100 && inactiveAlpha > 25 && activeAlpha > inactiveAlpha * 2, "Overlay raster shows both masks, emphasizing the selected one")
        model.isDrawingMask = false
        try check(model.overlayMasks.count == 1 && !model.edits.masks[0].overlayVisible, "Mouse-up restores the mask's hidden overlay setting")
        model.selectedMaskID = second.id
        try check(model.showOverlay && model.overlayMasks[0].alpha == 0.48, "Switching selection restores that mask's independent setting and emphasis")
        model.selectedMaskID = mask.id
        try check(!model.edits.masks[0].overlayVisible, "Switching back retains the first mask's hidden overlay")
        let perMaskState=model.edits
        model.showOverlay=false
        try check(model.overlayMasks.isEmpty && model.edits==perMaskState,"Master Overlay hides all masks without overwriting independent settings")
        model.selectedMaskID=second.id
        try check(!model.showOverlay && model.overlayMasks.isEmpty,"Selecting another mask does not turn the master Overlay back on")
        model.isDrawingMask=true
        try check(model.overlayMasks.count==1 && model.overlayMasks[0].mask.id==second.id,"Drawing temporarily bypasses the master switch only for the active mask")
        model.isDrawingMask=false;model.showOverlay=true
        try check(model.edits==perMaskState && model.overlayMasks.count==1,"Master Overlay restores each mask's original visibility")
        model.setMaskHandlesVisible(mask.id,false);model.selectedMaskID=mask.id
        try check(!model.selectedMaskHandlesVisible && model.edits.masks[1].handlesVisible,"Handle switch changes only its own mask")
        model.selectedMaskID=second.id
        try check(model.selectedMaskHandlesVisible,"Selecting a different mask uses that mask's own Handle setting")
        model.showHandles=false
        try check(!model.selectedMaskHandlesVisible && model.edits.masks[1].handlesVisible,"Master Handles does not overwrite individual settings")
        model.showHandles=true;model.selectedMaskID=mask.id
        try check(!model.selectedMaskHandlesVisible,"Restoring master Handles retains the first mask's hidden setting")
        let restored = try JSONDecoder().decode(EditState.self, from: JSONEncoder().encode(model.edits))
        try check(!restored.masks[0].overlayVisible && restored.masks[1].overlayVisible && !restored.masks[0].handlesVisible && restored.masks[1].handlesVisible, "Per-mask overlay and handle settings survive a settings round trip")
        let overlap = try engine.selectionOverlays([(mask,0.48),(mask,0.16)], source: source)
        try check(abs(Int(pixel(overlap,10,40)[3]) - Int((0.48+0.16*(1-0.48))*255)) <= 2, "Overlapping masks accumulate Overlay alpha with Source Over")
        var greenMask=mask;greenMask.overlayColor=[0,1,0]
        let mixed=try engine.selectionOverlays([(mask,0.48),(greenMask,0.16)],source:source)
        let mixedPixel=pixel(mixed,10,40)
        try check(mixedPixel[0]>20 && mixedPixel[1]>20 && Int(mixedPixel[3])>activeAlpha,"Different Overlay colors contribute together at an overlap")
        try check(pixel(mixed,150,40)==[0,0,0,0],"Overlay tint leaves pixels outside every mask transparent")
        model.isRendering = true
        model.edits.repairs = [RepairStroke()]
        model.edits.repairs[0].points = [.center]
        try check(model.isProcessingRepairs, "Pending repair render activates Processing")
        model.isRendering = false
        try check(!model.isProcessingRepairs, "Completed repair render clears Processing")
        model.isFindingRepairSource = true
        try check(model.isProcessingRepairs, "Source matching also activates Processing before a stroke exists")
        model.isFindingRepairSource = false
        model.overlayWork?.cancel()
        model.renderWork?.cancel()
        var geometry=EditState();geometry.geometry.angle=17;geometry.geometry.horizontal=40;geometry.geometry.autoCrop=true
        let opaque=CIImage(color:CIColor(red:0.4,green:0.5,blue:0.6)).cropped(to:CGRect(x:0,y:0,width:128,height:96))
        let resized=try engine.render(source:opaque,edits:geometry)
        try check(resized.width==128 && resized.height==96,"Automatic transform crop preserves source pixel dimensions")
        let bytes=[UInt8](resized.dataProvider!.data! as Data)
        try check(stride(from:3,to:bytes.count,by:4).allSatisfy{bytes[$0]==255},"Resized automatic crop contains no transparent edge")
        geometry.crop=CropRegion(x:0.25,y:0.125,width:0.5,height:0.75)
        let cropped=try engine.render(source:opaque,edits:geometry)
        try check(cropped.width==64 && cropped.height==72,"Explicit manual crop remains independent of preserve-size auto crop")
        return "Feature checks passed: \(count) assertions (Curves, Glasses/Eyes, local HSL, original-size Auto Crop, per-mask Overlay)."
    }
}
