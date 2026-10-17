import LumaDomain
import AppKit
import CoreImage

@MainActor enum RevisionChecks {
    static func run() throws -> String {
        let engine=ImagePipeline()
        var count=0, failures:[String]=[]
        func check(_ value:Bool,_ message:String) {if value {count+=1} else {failures.append(message)}}
        let source=CIImage(color:CIColor(red:0.2,green:0.35,blue:0.5)).cropped(to:CGRect(x:0,y:0,width:128,height:96))
        let neutral=bytes(try engine.render(source:source,edits:.init()))
        let groups:[(AdjustmentSection,(inout EditState)->Void)]=[
            (.allAdjustments,{$0.adjustments.exposure=1;$0.curves.master[1].y=0.7}),
            (.whiteBalance,{$0.adjustments.temperature=60}),(.light,{$0.adjustments.exposure=1}),
            (.color,{$0.adjustments.saturation = -80}),(.effects,{$0.adjustments.dehaze=100}),
            (.grain,{$0.adjustments.grain=90}),(.vignette,{$0.adjustments.vignette=80}),
            (.detail,{$0.adjustments.colorNoiseReduction=90}),(.optics,{$0.adjustments.defringe=80}),
            (.curves,{$0.curves.master[1].y=0.75}),(.hsl,{$0.hsl[4].hue=80}),
            (.pointColor,{$0.pointColor.enabled=true;$0.pointColor.color=[0.2,0.35,0.5];$0.pointColor.tolerance=1;$0.pointColor.luminance=80}),
            (.grading,{$0.grading.midtones.saturation=80}),(.calibration,{$0.calibration.shadowTint=80}),
            (.geometry,{$0.geometry.angle=12;$0.crop=CropRegion(x:0.1,y:0.1,width:0.8,height:0.8)}),
            (.transform,{$0.geometry.scale=60}),
            (.masks,{var mask=LocalMask(name:"Test",kind:.radial);mask.adjustments.exposure=1;$0.masks=[mask]})]
        for (group,setup) in groups {
            var edits=EditState();setup(&edits)
            let original=edits
            edits.disabledSections.insert(group)
            check(bytes(try engine.render(source:source,edits:edits))==neutral,"Hidden \(group.rawValue) is absent from the rendered image")
            edits.disabledSections.remove(group)
            check(edits==original,"Showing \(group.rawValue) preserves all original settings")
        }
        var local=EditState(), mask=LocalMask(name:"Local",kind:.radial)
        mask.adjustments.exposure=2;mask.disabledSections.insert(.light);local.masks=[mask]
        check(bytes(try engine.render(source:source,edits:local))==neutral,"Local group visibility is respected")
        let encoded=try JSONEncoder().encode(local)
        check(try JSONDecoder().decode(EditState.self,from:encoded)==local,"Visibility survives project serialization")
        let oldGeometry=Data("{\"angle\":2,\"scale\":100}".utf8)
        check(try JSONDecoder().decode(GeometrySettings.self,from:oldGeometry).autoCrop==false,"Old geometry receives a default auto-crop value")
        check(CurveSettings.line.count==3,"New curves start with three points")
        var points=CurveSettings.line
        let added=CurveEditing.insert(UnitPoint2D(x:0.75,y:0.4),into:&points)
        check(added==2 && points.count==4 && points[2].y==0.4,"Clicking empty curve space inserts a sorted point")
        CurveEditing.remove(0,from:&points);check(points.count==4,"Curve endpoints cannot be deleted")
        CurveEditing.remove(2,from:&points);check(points==CurveSettings.line,"Deleting an interior curve point preserves the others")
        check(NumericInput.parse("250",range:-100...100)==250,"Numeric entry can exceed the slider")
        check(NumericInput.parse("-350",range:-100...100) == -300,"Numeric input has a finite three-times limit")
        check(NumericInput.parse("150",range:0...1,multiplier:100)==1.5,"Percentage entry uses display units")
        check(NumericInput.parse("nan",range:-100...100)==nil,"Non-finite numeric input is rejected")
        check(NumericInput.parse("1,25",range:-5...5)==1.25,"Numeric input accepts decimal comma")
        var extendedBrush=LocalMask(name:"Extended",kind:.brush)
        extendedBrush.brushSize=0.2;extendedBrush.feather=0;extendedBrush.flow=3;extendedBrush.density=3
        extendedBrush.strokes=[[UnitPoint2D(x:0.3,y:0.5),UnitPoint2D(x:0.7,y:0.5)]]
        extendedBrush.erasedStrokes=extendedBrush.strokes;extendedBrush.adjustments.exposure=1
        var erasedEdit=EditState();erasedEdit.masks=[extendedBrush]
        let erasedPixels=bytes(try engine.render(source:source,edits:erasedEdit)), center=(48*128+64)*4
        check((center..<center+3).allSatisfy {abs(Int(erasedPixels[$0])-Int(neutral[$0]))<=1},"Eraser restores neutral image within 8-bit rendering tolerance")
        var erasedCoverage=[Float](repeating:0,count:4)
        erasedCoverage.withUnsafeMutableBytes { storage in
            CIContext(options:[.workingColorSpace:NSNull()]).render(engine.maskImage(extendedBrush,size:source.extent.size),toBitmap:storage.baseAddress!,rowBytes:16,bounds:CGRect(x:64,y:48,width:1,height:1),format:.RGBAf,colorSpace:nil)
        }
        check(abs(erasedCoverage[0])<0.00001,"Eraser fully removes coverage even above the slider range")
        for size in [CGSize(width:600,height:400),CGSize(width:3000,height:2000)] {
            let point=ViewportGeometry.normalizedPoint(CGPoint(x:size.width*0.7,y:size.height*0.6),in:CGRect(origin:.zero,size:size),flipped:true)
            check(abs(point.x-0.7)<0.000001 && abs(point.y-0.6)<0.000001,"Pointer normalization is independent of source pixel count")
            let opposite=ViewportGeometry.normalizedPoint(CGPoint(x:size.width*0.7,y:size.height*0.4),in:CGRect(origin:.zero,size:size),flipped:false)
            check(abs(opposite.y-0.6)<0.000001,"Non-flipped native view coordinates map to top-left image coordinates")
        }
        for scale in [50.0,150.0] {
            var edits=EditState();edits.geometry.scale=scale
            let image=try engine.render(source:source,edits:edits), data=bytes(image)
            check(image.width==128 && image.height==96,"Geometry Scale keeps a fixed output canvas")
            if scale<100 {check(data[3]==0 && data[(48*128+64)*4+3]==255,"Scale below 100 shrinks rather than enlarges the image")}
            else {check(stride(from:3,to:data.count,by:4).allSatisfy{data[$0]==255},"Scale above 100 fills the canvas")}
        }
        let transformations:[(inout GeometrySettings)->Void]=[{$0.scale=50},{$0.angle=12},{$0.horizontal=80},{$0.offsetX=25},{$0.offsetY = -25}]
        for setup in transformations {
            var edits=EditState();setup(&edits.geometry);edits.geometry.autoCrop=true
            let image=try engine.render(source:source,edits:edits), data=bytes(image)
            check(image.width==128 && image.height==96,"Auto-crop preserves original pixel dimensions after removing empty edges")
            check(stride(from:3,to:data.count,by:4).allSatisfy{data[$0]==255},"Auto-crop leaves no transparent output pixels")
            check(try engine.outputSize(source:source,edits:edits)==CGSize(width:image.width,height:image.height),"Auto-crop viewport and full render dimensions agree")
        }
        var noTransform=EditState();noTransform.geometry.autoCrop=true
        let untouched=try engine.render(source:source,edits:noTransform)
        check(untouched.width==128 && untouched.height==96,"Auto-crop preserves a fully opaque untransformed image")
        let rectangle=GeometryAutoCrop.largestRectangle(width:4,height:3,opaque:[false,true,true,true,false,true,true,true,false,false,true,true])
        check(rectangle.width*rectangle.height==6,"Auto-crop finds the largest opaque rectangle rather than its bounding box")
        let flat=CIImage(color:CIColor(red:0.35,green:0.35,blue:0.35)).cropped(to:CGRect(x:0,y:0,width:512,height:384))
        let flatNeutral=bytes(try engine.render(source:flat,edits:.init()))
        var grain=EditState();grain.adjustments.grain=100
        let grained=bytes(try engine.render(source:flat,edits:grain))
        func average(_ values:[UInt8])->Double {Double(stride(from:0,to:values.count,by:4).reduce(0){$0+Int(values[$1])})/Double(values.count/4)}
        check(abs(average(grained)-average(flatNeutral))<1,"Grain preserves average displayed midtone brightness")
        check(grained != flatNeutral,"Grain adds actual texture")
        check(grained==bytes(try engine.render(source:flat,edits:grain)),"Grain is deterministic across preview and export requests")
        var extended=EditState();extended.adjustments.contrast=200
        var normal=EditState();normal.adjustments.contrast=100
        check(bytes(try engine.render(source:source,edits:extended)) != bytes(try engine.render(source:source,edits:normal)),"Contrast numeric over-range changes actual rendering")
        let dark=CIImage(color:CIColor(red:0.001,green:0.001,blue:0.001)).cropped(to:CGRect(x:0,y:0,width:32,height:32))
        normal.adjustments = .neutral;normal.adjustments.exposure=5
        extended.adjustments = .neutral;extended.adjustments.exposure=6
        check(bytes(try engine.render(source:dark,edits:extended))[0]>bytes(try engine.render(source:dark,edits:normal))[0],"Exposure above the slider range is effective")
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("lumalab-session-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let original=try engine.exportPNG(source:source,edits:.init()), file=folder.appendingPathComponent("session.png")
        try original.write(to:file)
        let model=EditorModel(loadWorkspace:false)
        try model.load(data:original,name:"session.png");model.sourceURL=file
        check(model.showOverlay && model.showHandles,"Mask overlay and handles default to visible")
        model.edits.adjustments.exposure=1;model.commit();model.addSnapshot(name:"Pending")
        RunLoop.current.run(until:Date().addingTimeInterval(0.95))
        check(!FileManager.default.fileExists(atPath:WorkflowStore.sidecarURL(for:file).path),"Editing and snapshots do not write a sidecar before Done")
        model.cancelEditing()
        check(model.edits==EditState() && model.snapshots.isEmpty && !model.isModified,"Cancel restores the full saved checkpoint")
        model.edits.adjustments.exposure=1;model.commit();model.addSnapshot(name:"Saved")
        model.finishEditing()
        let savedData=try Data(contentsOf:WorkflowStore.sidecarURL(for:file))
        let saved=try WorkflowStore.readSidecar(for:file,data:original)
        check(saved?.edits.adjustments.exposure==1 && saved?.snapshots.count==1 && !model.isModified,"Done persists parameters and snapshots")
        model.edits.adjustments.exposure=2;model.commit();model.toggleSection(.light);model.cancelEditing()
        check(model.edits.adjustments.exposure==1 && model.sectionVisible(.light),"Cancel restores parameters and visibility after a previous Done")
        check(try Data(contentsOf:WorkflowStore.sidecarURL(for:file))==savedData,"Cancel does not change the saved sidecar bytes")
        check(try Data(contentsOf:file)==original,"Done and Cancel preserve original image bytes")
        model.edits.hsl[0].hue=30;model.edits.hsl[1].hue=40
        model.resetHSLBand(0)
        check(model.edits.hsl[0].hue==0 && model.edits.hsl[1].hue==40 && model.edits.adjustments.exposure==1,"HSL Reset Group only resets the chosen color")
        model.resetSection(.hsl)
        check(model.edits.hsl==HSLBand.defaults && model.edits.adjustments.exposure==1,"HSL Reset All preserves other editing sections")
        model.workspace.library=[PhotoLibraryItem(path:file.path)];model.librarySelection=[file.path]
        var copied=EditState();copied.adjustments.exposure=2;model.copiedSettings=copied
        model.applyCopiedToSelection()
        let deadline=Date().addingTimeInterval(3)
        while model.batchRunning && Date()<deadline {RunLoop.current.run(until:Date().addingTimeInterval(0.02))}
        check(!model.batchRunning && model.edits.adjustments.exposure==2 && model.isModified,"Batch apply to the current document remains pending")
        check(try Data(contentsOf:WorkflowStore.sidecarURL(for:file))==savedData,"Batch apply does not bypass Done for the current document")
        model.cancelEditing()
        model.renderWork?.cancel()
        if !failures.isEmpty {throw EngineChecks.Failure(message:failures.joined(separator:"\n"))}
        return "通过 — \(count) 项 0.3 回归检查（原生坐标、分组显隐、数值输入、自动裁剪、颗粒亮度、完成与取消）。"
    }
    private static func bytes(_ image:CGImage)->[UInt8] {
        var values=[UInt8](repeating:0,count:image.width*image.height*4)
        values.withUnsafeMutableBytes { buffer in
            let context=CGContext(data:buffer.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,
                                  space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        }
        return values
    }
}
