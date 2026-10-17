import LumaDomain
import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

@MainActor enum AdvancedChecks {
    static func run() throws -> String {
        var count=0
        func check(_ ok:Bool,_ text:String) throws {guard ok else {throw NSError(domain:"AdvancedChecks",code:count,userInfo:[NSLocalizedDescriptionKey:text])};count+=1}
        var text="LUT_3D_SIZE 2\n"
        for b in 0...1 {for g in 0...1 {for r in 0...1 {text+="\(b) \(g) \(r)\n"}}}
        let cube=try CubeLUT(text:text,name:"swap")
        let mapped=cube.apply(0.2,0.4,0.8)
        try check(abs(mapped.0-0.8)<0.0001 && abs(mapped.2-0.2)<0.0001,"Cube order and trilinear interpolation")
        var rejected=false;do {_=try CubeLUT(text:"LUT_3D_SIZE 4096",name:"bad")} catch {rejected=true}
        try check(rejected,"Reject invalid LUT size")
        let component=try JSONDecoder().decode(MaskComponent.self,from:Data("{\"kind\":\"brush\"}".utf8))
        try check(component.edgeStrokes.isEmpty,"Legacy component decodes without Auto Mask fields")
        let w=96,h=64
        var rgba=[UInt8](repeating:255,count:w*h*4)
        for y in 0..<h {for x in 0..<w {let i=(y*w+x)*4;rgba[i]=x>=45 && x<51 ? 0:255;rgba[i+1]=0;rgba[i+2]=x>=45 && x<51 ? 255:0}}
        var stroke=EdgeBrushStroke();stroke.points=[UnitPoint2D(x:0.3,y:0.5)];stroke.color=[1,0,0];stroke.diameter=2;stroke.feather=0
        let coverage=EdgeAwareBrush.coverage(stroke,rgba:rgba,width:w,height:h)
        try check(coverage[32*w+30]>200 && coverage[32*w+48]==0,"Auto Mask follows sampled color")
        try check(coverage[32*w+65]==0,"Auto Mask cannot flood across a contrasting barrier")
        var base=EditState(),target=EditState();base.adjustments.exposure=0.5;target.adjustments.exposure=2.5
        let half=PresetInterpolation.apply(base:base,target:target,amount:0.5)
        try check(abs(half.adjustments.exposure-1.5)<0.0001,"Preset Amount interpolates from pre-preset state")
        try check(PresetInterpolation.apply(base:base,target:target,amount:0)==base,"Preset zero exactly restores base")
        try check(abs(PortableStack.sigmaClippedMean([0.2,0.2,0.21,0.19,1])-0.2)<0.005,"Sigma clipping rejects an isolated bright outlier")
        try check(PortableStack.isGhost(samples:[[0.2,0.2,0.2],[0.8,0.2,0.2]],gains:[1,1],reference:0,threshold:0.2),"Deghost detects normalized color disagreement")
        try check(!PortableStack.isGhost(samples:[[0.2,0.2,0.2],[0.4,0.4,0.4]],gains:[1,0.5],reference:0,threshold:0.2),"Deghost preserves consistent bracket exposures")
        let engine=ImagePipeline(),source=CIImage(color:CIColor(red:0.3,green:0.5,blue:0.8)).cropped(to:CGRect(x:0,y:0,width:64,height:48))
        let normal=try engine.render(source:source,edits:.init())
        var proof=ProofOptions();proof.enabled=true
        let proofed=try SoftProof.render(normal,options:proof)
        let floatProof=try SoftProof.render(engine.proofSource(source:source,edits:.init()),options:proof)
        try check(floatProof.width==normal.width,"Soft Proof accepts linear float input before display gamut clipping")
        try check(proofed.width==64 && proofed.height==48,"ICC Proof round trip produces a preview")
        proof.gamutWarning=true
        let warning=try SoftProof.render(normal,options:proof)
        let proofBytes=[UInt8](proofed.dataProvider!.data! as Data),warningBytes=[UInt8](warning.dataProvider!.data! as Data)
        try check(zip(proofBytes,warningBytes).allSatisfy {abs(Int($0)-Int($1))<=1},"sRGB colors are not falsely marked outside sRGB Gamut")
        proof.profile=try Data(contentsOf:URL(fileURLWithPath:"/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc"))
        _=try SoftProof.render(normal,options:proof)
        try check(true,"CMYK ICC Proof and Gamut Check execute")
        // Deterministic textured feature fixture, including rotation and a displaced crop.
        let size=256
        var pixels=[UInt8](repeating:255,count:size*size*4)
        var seed:UInt64=937
        var blocks=[UInt8](repeating:0,count:64*64)
        for i in blocks.indices {seed=seed &* 6364136223846793005 &+ 1;blocks[i]=UInt8((seed>>32)%220+20)}
        for y in 0..<size {for x in 0..<size {let value=blocks[(y/4)*64+x/4];for c in 0..<3 {pixels[(y*size+x)*4+c]=value}}}
        var shifted=[UInt8](repeating:0,count:pixels.count)
        for y in 0..<size {for x in 0..<size {let sx=x-9,sy=y+6;let i=(y*size+x)*4;shifted[i+3]=255;if sx>=0 && sx<size && sy>=0 && sy<size {for c in 0..<3 {shifted[i+c]=pixels[(sy*size+sx)*4+c]}}}}
        let alignment=try PortableRegistration.align(reference:pixels,rw:size,rh:size,moving:shifted,mw:size,mh:size)
        let p=alignment.point(128,128)
        try check(hypot(p.x-119,p.y-134)<1.5,"Portable registration recovers translation")
        let homography=try PortableRegistration.align(reference:pixels,rw:size,rh:size,moving:shifted,mw:size,mh:size,projective:true)
        let q=homography.point(128,128)
        try check(hypot(q.x-119,q.y-134)<1.5,"Projective registration recovers overlapping image geometry")
        var rotated=[UInt8](repeating:255,count:pixels.count)
        let angle=3.0*Double.pi/180,c=cos(angle),sn=sin(angle)
        for y in 0..<size {for x in 0..<size {
            let xx=c*Double(x-128)-sn*Double(y-128)+128,yy=sn*Double(x-128)+c*Double(y-128)+128
            if xx>=0 && xx<Double(size-1) && yy>=0 && yy<Double(size-1) {
                let sx=Int(xx),sy=Int(yy),u=xx-Double(sx),v=yy-Double(sy)
                let a=Double(pixels[(sy*size+sx)*4]),b=Double(pixels[(sy*size+sx+1)*4]),d=Double(pixels[((sy+1)*size+sx)*4]),e=Double(pixels[((sy+1)*size+sx+1)*4])
                let value=UInt8(min(255,max(0,(a*(1-u)+b*u)*(1-v)+(d*(1-u)+e*u)*v)))
                for channel in 0..<3 {rotated[(y*size+x)*4+channel]=value}
            }
        }}
        let rotation=try PortableRegistration.align(reference:pixels,rw:size,rh:size,moving:rotated,mw:size,mh:size)
        let rr=rotation.point(60,60),expected=UnitPoint2D(x:c * -68-sn * -68+128,y:sn * -68+c * -68+128)
        try check(hypot(rr.x-expected.x,rr.y-expected.y)<2.0,"Portable rigid Registration recovers a 3 degree rotation")
        let temporary=FileManager.default.temporaryDirectory.appendingPathComponent("LumaLab-Advanced-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:temporary)}
        let space=CGColorSpace(name:CGColorSpace.sRGB)!
        func bitmap(_ values:[UInt8],width:Int,height:Int)->CGImage {
            CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:space,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:CGDataProvider(data:Data(values) as CFData)!,decode:nil,shouldInterpolate:true,intent:.defaultIntent)!
        }
        // Exercise persisted edge strokes through the same Coverage and local-color pipeline as the canvas.
        var edgePixels=rgba
        for i in edgePixels.indices where i % 4 != 3 {edgePixels[i] = edgePixels[i] == 255 ? 128 : 20}
        let edgeSource=CIImage(cgImage:bitmap(edgePixels,width:w,height:h))
        var edgeMask=LocalMask(name:"edge-render",kind:.brush)
        stroke.color=engine.sampledRGB(source:edgeSource,point:stroke.points[0]);edgeMask.edgeStrokes=[stroke];edgeMask.adjustments.exposure=1
        let edgeCoverage=try engine.coveragePreview(edgeMask,source:edgeSource)
        let edgeBytes=[UInt8](edgeCoverage.dataProvider!.data! as Data)
        try check(edgeBytes[32*edgeCoverage.bytesPerRow+30*4]>240 && edgeBytes[32*edgeCoverage.bytesPerRow+65*4]==0,"Auto Mask Coverage follows the barrier through the real renderer")
        var edgeState=EditState();edgeState.masks=[edgeMask]
        let edgeBefore=try engine.render(source:edgeSource,edits:.init()),edgeAfter=try engine.render(source:edgeSource,edits:edgeState)
        let eb=[UInt8](edgeBefore.dataProvider!.data! as Data),ea=[UInt8](edgeAfter.dataProvider!.data! as Data)
        let selectedPixel=32*edgeAfter.bytesPerRow+30*4,otherPixel=32*edgeAfter.bytesPerRow+65*4
        try check(Int(ea[selectedPixel])-Int(eb[selectedPixel])>30 && abs(Int(ea[otherPixel])-Int(eb[otherPixel]))<=1,"Auto Mask applies local Exposure only to the connected selected area")
        stroke.erase=true;edgeMask.edgeStrokes.append(stroke)
        let erased=try engine.coveragePreview(edgeMask,source:edgeSource)
        let erasedBytes=[UInt8](erased.dataProvider!.data! as Data)
        try check(erasedBytes[32*erased.bytesPerRow+30*4]==0,"Auto Mask Erase removes the same rendered Coverage")
        func write(_ image:CGImage,_ name:String) throws -> URL {
            let url=temporary.appendingPathComponent(name+".png")
            let destination=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
            CGImageDestinationAddImage(destination,image,nil)
            guard CGImageDestinationFinalize(destination) else {throw ImagePipeline.PipelineError.renderFailed};return url
        }
        let full=bitmap(pixels,width:size,height:size)
        let left=try write(full.cropping(to:CGRect(x:0,y:0,width:192,height:256))!,"pano-left")
        let right=try write(full.cropping(to:CGRect(x:64,y:0,width:192,height:256))!,"pano-right")
        let panorama=try PanoramaProcessor.combine(urls:[left,right],progress:{_ in})
        try check(panorama.image.extent.width>=250 && panorama.image.extent.width<=265,"Panorama composes overlapping frames into a wider image")
        _=try engine.render(source:panorama.image,edits:.init(),maxDimension:256)
        try check(true,"Panorama blend evaluates into real output pixels")
        let rawImage=CIImage(cgImage:full),blur=rawImage.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:3]).cropped(to:rawImage.extent)
        let leftRect=CGRect(x:0,y:0,width:128,height:256),rightRect=CGRect(x:128,y:0,width:128,height:256)
        let focusA=rawImage.cropped(to:leftRect).composited(over:blur.cropped(to:rightRect))
        let focusB=rawImage.cropped(to:rightRect).composited(over:blur.cropped(to:leftRect))
        let ctx=CIContext(options:[.workingColorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!])
        let fa=try write(ctx.createCGImage(focusA,from:rawImage.extent,format:.RGBA8,colorSpace:space)!,"focus-a")
        let fb=try write(ctx.createCGImage(focusB,from:rawImage.extent,format:.RGBA8,colorSpace:space)!,"focus-b")
        let focused=try StackProcessor.combine(urls:[fa,fb],mode:.focus,align:false)
        let focusedCG=try engine.render(source:focused.image,edits:.init())
        let focusedBytes=[UInt8](focusedCG.dataProvider!.data! as Data)
        var error:Double=0,blurError:Double=0
        let blurry=ctx.createCGImage(blur,from:rawImage.extent,format:.RGBA8,colorSpace:space)!,blurryBytes=[UInt8](blurry.dataProvider!.data! as Data)
        for y in 8..<(size-8) {for x in 8..<(size-8) where abs(x-128)>8 {
            error+=abs(Double(focusedBytes[y*focusedCG.bytesPerRow+x*4])-Double(pixels[(y*size+x)*4]))
            blurError+=abs(Double(blurryBytes[y*blurry.bytesPerRow+x*4])-Double(pixels[(y*size+x)*4]))
        }}
        try check(error<blurError*0.65,"Focus Stacking preserves sharp detail on both sides")
        let rawURL=ProcessInfo.processInfo.environment["LUMALAB_DNG_FIXTURE"].map {URL(fileURLWithPath:$0)}
        if let rawURL,FileManager.default.fileExists(atPath:rawURL.path) {
            let decoded=try SharedRAWDecoder.decode(Data(contentsOf:rawURL,options:.mappedIfSafe))
            try check(decoded.width*decoded.height>1000000 && decoded.rgb16.count==decoded.width*decoded.height*6,"Shared LibRaw decodes a real camera DNG into full-resolution RGB16")
        }
        var semantic=LocalMask(name:"source-subject",kind:.automatic)
        semantic.automaticKind = .subject;semantic.automaticIndex=0;semantic.adjustments.exposure=1.2
        semantic.raster=try PortableMaskRaster(width:2,height:1,pixels:Data([255,0]),modelID:"source")
        var copied=EditState();copied.masks=[semantic]
        var destinationWidth=0
        let adaptive=try AdaptiveMaskSync.refresh(copied,data:Data(contentsOf:left),fileExtension:"png") {kind,image in
            destinationWidth=image.width
            return [AutomaticMaskResult(name:"destination",raster:try PortableMaskRaster(width:2,height:1,pixels:Data([0,255]),modelID:"destination"),backend:"fixture")]
        }
        try check(destinationWidth==192 && adaptive.masks[0].raster?.pixels==Data([0,255]),"Adaptive Sync runs recognition on the destination photo")
        try check(adaptive.masks[0].id==semantic.id && adaptive.masks[0].adjustments==semantic.adjustments,"Adaptive Sync preserves mask identity and edits")
        copied.masks[0].automaticIndex=2;rejected=false
        do {_=try AdaptiveMaskSync.refresh(copied,data:Data(contentsOf:left),fileExtension:"png") {_,_ in []}} catch {rejected=true}
        try check(rejected,"Missing destination subject fails without reusing the source raster")
        let model=EditorModel(loadWorkspace:false)
        var maskA=LocalMask(name:"A",kind:.automatic),maskB=LocalMask(name:"B",kind:.automatic)
        maskA.raster=try PortableMaskRaster(width:2,height:1,pixels:Data([255,0]),modelID:"left")
        maskB.raster=try PortableMaskRaster(width:2,height:1,pixels:Data([0,255]),modelID:"right");maskB.adjustments.exposure=0.7
        model.edits.masks=[maskA,maskB];model.selectedMaskID=maskB.id;model.maskSelection=[maskA.id,maskB.id]
        model.groupSelectedMasks()
        let group=model.edits.masks[0].groupID
        try check(group != nil && model.edits.masks[1].groupID==group,"Mask Group persists membership")
        model.toggleMaskGroup(group!)
        try check(model.edits.masks.allSatisfy {!$0.enabled},"Group Eye toggles every member")
        model.toggleMaskGroup(group!);model.mergeSelectedMasks()
        try check(model.edits.masks.count==1 && model.edits.masks[0].adjustments.exposure==0.7,"Merge Coverage keeps the active mask's adjustments")
        let mergedPixels=model.edits.masks[0].raster!.pixels
        try check(mergedPixels.first!>250 && mergedPixels.last!>250,"Merged Coverage includes both disjoint selected areas")
        model.renderWork?.cancel();model.overlayWork?.cancel()
        var lutState=EditState();lutState.lut.cube=cube
        let colored=try engine.render(source:source,edits:lutState)
        try check((colored.dataProvider!.data! as Data) != (normal.dataProvider!.data! as Data),"Imported LUT changes rendered pixels")
        lutState.disabledSections.insert(.allAdjustments)
        let hidden=try engine.render(source:source,edits:lutState)
        try check((hidden.dataProvider!.data! as Data)==(normal.dataProvider!.data! as Data),"Global adjustments Eye disables LUT too")
        let directory=WorkflowStore.directoryOverride
        WorkflowStore.directoryOverride=FileManager.default.temporaryDirectory.appendingPathComponent("Recovery-check-"+UUID().uuidString)
        defer {RecoveryStore.clear();WorkflowStore.directoryOverride=directory}
        let data=try DemoImage.make(),digest=WorkflowStore.digest(data)
        let record=RecoveryRecord(sourceName:"recovery.png",dataFilename:digest+".source",digest:digest,edits:target,savedState:base,snapshots:[],virtualCopies:[],history:[base,target],historyIndex:1,structureDirty:false,newDocument:false)
        try RecoveryStore.write(record,data:data)
        let startup=EditorModel(loadWorkspace:true)
        startup.ioQueue.sync {}
        try check(FileManager.default.fileExists(atPath:RecoveryStore.manifest.path),"Startup demo cannot delete unreviewed Recovery")
        startup.renderWork?.cancel();startup.overlayWork?.cancel()
        let restored=try RecoveryStore.read()
        try check(restored?.0.edits==target && restored?.0.savedState==base && restored?.1==data,"Recovery preserves source, pending state and save baseline")
        RecoveryStore.clear();try check(try RecoveryStore.read()==nil,"Explicit close clears only the owned Recovery record")
        return "Advanced checks passed: \(count) (LUT, Auto Mask, Preset, Stack, Registration, ICC, Recovery)."
    }
}
