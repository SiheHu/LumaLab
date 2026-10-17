import LumaDomain
import Foundation
import CoreImage
import AppKit

@MainActor enum RepairChecks {
    struct Failure:LocalizedError {
        var message:String
        var errorDescription:String? {message}
    }
    static func run() throws -> String {
        var count=0
        func check(_ condition:Bool,_ message:String) throws {guard condition else {throw Failure(message:message)};count+=1}
        let renderer=ImagePipeline(),context=CIContext(options:[.workingColorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!])
        let space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
        let w=160,h=120
        var clean=[Float](repeating:1,count:w*h*4)
        for y in 0..<h {for x in 0..<w {
            let i=(y*w+x)*4
            clean[i]=0.15+Float(x)/Float(w)*0.4
            clean[i+1]=0.2+Float(y)/Float(h)*0.3
            clean[i+2]=0.3+Float(x+y)/Float(w+h)*0.15
        }}
        func image(_ values:[Float])->CIImage {CIImage(bitmapData:values.withUnsafeBytes {Data($0)},bytesPerRow:w*16,size:CGSize(width:w,height:h),format:.RGBAf,colorSpace:space)}
        let ground=image(clean)
        var dirty=clean
        let target=UnitPoint2D(x:0.65,y:0.3),sample=UnitPoint2D(x:0.25,y:0.65)
        let tx=Int(target.x*Double(w)),ty=Int(target.y*Double(h))
        for y in 0..<h {for x in 0..<w where hypot(Double(x-tx),Double(y-ty))<5 {for c in 0..<3 {dirty[(y*w+x)*4+c]=0.015}}}
        let source=image(dirty)
        func pixel(_ image:CIImage,_ p:UnitPoint2D)->[Float] {
            var result=[Float](repeating:0,count:4)
            result.withUnsafeMutableBytes {context.render(image,toBitmap:$0.baseAddress!,rowBytes:16,bounds:CGRect(x:Int(p.x*Double(w)),y:Int((1-p.y)*Double(h)),width:1,height:1),format:.RGBAf,colorSpace:space)}
            return result
        }
        var full=[Float](repeating:0,count:w*h*4)
        full.withUnsafeMutableBytes {context.render(ground,toBitmap:$0.baseAddress!,rowBytes:w*16,bounds:ground.extent,format:.RGBAf,colorSpace:space)}
        let reference=pixel(ground,target), row=(Int(target.y*Double(h))*w+tx)*4
        try check((0..<3).allSatisfy {abs(full[row+$0]-reference[$0])<0.005},"Bitmap row ordering agrees with normalized top-left source matching")
        var stroke=RepairStroke();stroke.points=[target];stroke.source=sample;stroke.radius=0.1;stroke.feather=0.35
        stroke.mode = .clone
        let clone=try renderer.repairProcessor.apply(source:source,strokes:[stroke])
        let a=pixel(clone,target),b=pixel(source,sample)
        try check((0..<3).allSatisfy {abs(a[$0]-b[$0])<0.005},"Clone samples the correct normalized source position")
        stroke.mode = .heal
        let healed=try renderer.repairProcessor.apply(source:source,strokes:[stroke])
        let expected=pixel(ground,target),actual=pixel(healed,target),bad=pixel(source,target)
        let healedError=(0..<3).reduce(Float(0)) {$0+abs(expected[$1]-actual[$1])}
        let badError=(0..<3).reduce(Float(0)) {$0+abs(expected[$1]-bad[$1])}
        try check(badError>0.2,"Synthetic target contains the intended blemish")
        try check(healedError<0.03 && healedError<badError*0.1,"Heal removes the synthetic blemish and matches target illumination: \(healedError)")
        try check(pixel(healed,UnitPoint2D(x:0.1,y:0.1))==pixel(source,UnitPoint2D(x:0.1,y:0.1)),"Repair leaves distant pixels unchanged")
        try check(pixel(try renderer.repairProcessor.apply(source:source,strokes:[stroke]),target)==actual,"Cached Heal output is deterministic")
        var disabled=stroke;disabled.enabled=false
        try check(pixel(try renderer.repairProcessor.apply(source:source,strokes:[disabled]),target)==bad,"Disabled repair preserves original pixels")
        var zero=stroke;zero.opacity=0
        try check(pixel(try renderer.repairProcessor.apply(source:source,strokes:[zero]),target)==bad,"Zero repair opacity is a no-op")
        var partial=stroke;partial.opacity=0.5
        let half=pixel(try renderer.repairProcessor.apply(source:source,strokes:[partial]),target)
        try check(half[0]>bad[0] && half[0]<actual[0],"Repair opacity blends with original")
        var translucent=clean
        for i in stride(from:0,to:translucent.count,by:4) {for c in 0..<3 {translucent[i+c]*=0.5};translucent[i+3]=0.5}
        let alphaSource=image(translucent)
        let alphaResult=try renderer.repairProcessor.apply(source:alphaSource,strokes:[stroke])
        try check(abs(pixel(alphaResult,target)[3]-0.5)<0.001,"Local patch replacement preserves source alpha")
        var line=stroke;line.mode = .clone;line.points=[UnitPoint2D(x:0.45,y:0.2),UnitPoint2D(x:0.7,y:0.2)];line.source=UnitPoint2D(x:0.2,y:0.7);line.radius=0.04
        let lineResult=try renderer.repairProcessor.apply(source:source,strokes:[line])
        let middle=UnitPoint2D(x:0.575,y:0.2),lineSample=UnitPoint2D(x:0.325,y:0.7)
        let l=pixel(lineResult,middle),r=pixel(source,lineSample)
        try check((0..<3).allSatisfy {abs(l[$0]-r[$0])<0.006},"Continuous stroke keeps a constant source offset")
        let uniform=CIImage(color:CIColor(red:0.4,green:0.4,blue:0.4)).cropped(to:CGRect(x:0,y:0,width:1800,height:1200))
        var noOp=RepairStroke();noOp.mode = .clone;noOp.points=[target];noOp.source=target
        var noOpEdits=EditState();noOpEdits.repairs=[noOp]
        func rgba(_ image:CGImage)->[UInt8] {let data=Array(image.dataProvider!.data! as Data);return (0..<image.height).flatMap {row in Array(data[(row*image.bytesPerRow)..<(row*image.bytesPerRow+image.width*4)])}}
        let baseline=rgba(try renderer.render(source:uniform,edits:.init(),maxDimension:1600))
        let patched=rgba(try renderer.render(source:uniform,edits:noOpEdits,maxDimension:1600))
        let delta=zip(baseline,patched).map {abs(Int($0)-Int($1))}
        let maximum=delta.max() ?? 0,index=delta.firstIndex(of:maximum) ?? 0
        try check(maximum<=1,"Proxy interpolation never creates a dark rectangular patch border: delta=\(maximum) at byte \(index), values \(baseline[index]) / \(patched[index]), lengths \(baseline.count) / \(patched.count)")
        // A flat source ring can hide another defect at the source center.
        // The old boundary-only matcher had no evidence about those pixels.
        let mw=320,mh=240
        var dustPixels=[UInt8](repeating:128,count:mw*mh*4)
        for i in stride(from:3,to:dustPixels.count,by:4) {dustPixels[i]=255}
        let dustTarget=UnitPoint2D(x:0.5,y:0.5),dustRadius=6.0
        func addDust(_ x:Int,_ y:Int) {
            for yy in max(0,y-4)...min(mh-1,y+4) {for xx in max(0,x-4)...min(mw-1,x+4) where hypot(Double(xx-x),Double(yy-y))<4 {
                for c in 0..<3 {dustPixels[(yy*mw+xx)*4+c]=3}
            }}
        }
        addDust(160,120)
        // These are the nearest old ring candidates, all contaminated centrally.
        for i in 0..<40 {
            let angle=Double(i)*Double.pi/20
            addDust(160+Int((cos(angle)*dustRadius*2.8).rounded()),120+Int((sin(angle)*dustRadius*2.8).rounded()))
        }
        guard let cleanSample=PortableHealing.findSource(pixels:dustPixels,width:mw,height:mh,points:[dustTarget],radius:dustRadius,variant:0) else {throw Failure(message:"Dust matcher finds no source")}
        let selected=(Int((cleanSample.y*Double(mh)).rounded())*mw+Int((cleanSample.x*Double(mw)).rounded()))*4
        try check(dustPixels[selected]>100,"Automatic matching rejects a second dust speck inside an otherwise matching source boundary")
        try check(PortableHealing.findSource(pixels:dustPixels,width:mw,height:mh,points:[dustTarget],radius:dustRadius,variant:Int.min) != nil,"Source alternative selection handles all integer variants")
        let correction=PortableHealing.correctionSize(width:4000,height:30,radius:12)
        try check(correction.1>=20 && correction.0>=2000,"Long thin strokes retain correction sampling across the brush width")
        let capped=PortableHealing.correctionSize(width:5000,height:4000,radius:2)
        try check(capped.0*capped.1<530000,"Correction sampling has a bounded pixel budget")
        // A textured source at a different illumination must retain its texture
        // while removing a dark defect. This is more demanding than a flat field.
        let tw=320,th=240
        var texture=[Float](repeating:1,count:tw*th*4)
        for yy in 0..<th {for xx in 0..<tw {
            let value=Float(0.3+0.001*Double(xx)+0.0004*Double(yy)+0.035*sin(Double(xx)*Double.pi/8)*cos(Double(yy)*Double.pi/8))
            for c in 0..<3 {texture[(yy*tw+xx)*4+c]=value}
        }}
        func textureImage(_ values:[Float])->CIImage {CIImage(bitmapData:values.withUnsafeBytes {Data($0)},bytesPerRow:tw*16,size:CGSize(width:tw,height:th),format:.RGBAf,colorSpace:space)}
        var defect=texture
        let tt=UnitPoint2D(x:0.6,y:0.4),ss=UnitPoint2D(x:tt.x-0.2,y:tt.y+0.2)
        for yy in 0..<th {for xx in 0..<tw where hypot(Double(xx)-tt.x*Double(tw),Double(yy)-tt.y*Double(th))<6 {for c in 0..<3 {defect[(yy*tw+xx)*4+c]=0.01}}}
        var texturedRepair=RepairStroke();texturedRepair.points=[tt];texturedRepair.source=ss;texturedRepair.radius=0.065;texturedRepair.feather=0.25
        let texturedResult=try renderer.repairProcessor.apply(source:textureImage(defect),strokes:[texturedRepair])
        func texturePixels(_ image:CIImage)->[Float] {var result=[Float](repeating:0,count:tw*th*4);result.withUnsafeMutableBytes {context.render(image,toBitmap:$0.baseAddress!,rowBytes:tw*16,bounds:image.extent,format:.RGBAf,colorSpace:space)};return result}
        let textureGround=texturePixels(textureImage(texture)),textureActual=texturePixels(texturedResult),textureBad=texturePixels(textureImage(defect))
        var healedTextureError=0.0,badTextureError=0.0,n=0
        for yy in 0..<th {for xx in 0..<tw where hypot(Double(xx)-tt.x*Double(tw),Double(yy)-tt.y*Double(th))<5 {
            let i=(yy*tw+xx)*4
            healedTextureError+=abs(Double(textureActual[i]-textureGround[i]));badTextureError+=abs(Double(textureBad[i]-textureGround[i]));n+=1
        }}
        try check(healedTextureError/Double(n)<0.012 && healedTextureError<badTextureError*0.05,"Healing preserves sampled texture across an illumination gradient: \(healedTextureError/Double(n))")
        // Quadratic illumination is Biharmonic but not Harmonic. Holding a
        // two-pixel ring fixes both value and slope; a flat-only fixture cannot
        // reveal the harmonic solver's bowl-shaped illumination error.
        let cw=65,ch=57
        var curvature=[Float](repeating:1,count:cw*ch*4),holes=[Bool](repeating:false,count:cw*ch)
        for y in 0..<ch {for x in 0..<cw {
            let dx=Double(x-cw/2),dy=Double(y-ch/2),value=Float(0.02+0.00015*dx*dx+0.0001*dy*dy+0.00006*dx*dy)
            for c in 0..<3 {curvature[(y*cw+x)*4+c]=value*Float(c+1)/3}
            holes[y*cw+x]=hypot(dx,dy)<17
        }}
        var incomplete=curvature
        for i in 0..<cw*ch where holes[i] {for c in 0..<3 {incomplete[i*4+c] = -0.4}}
        let harmonic=PortableHealing.solve(diff:incomplete,unknown:holes,width:cw,height:ch)
        let biharmonic=PortableHealing.solveBiharmonic(diff:incomplete,unknown:holes,width:cw,height:ch)
        var harmonicError=0.0,biharmonicError=0.0,curveN=0
        for i in 0..<cw*ch where holes[i] {harmonicError+=abs(Double(harmonic[i*4]-curvature[i*4]));biharmonicError+=abs(Double(biharmonic[i*4]-curvature[i*4]));curveN+=1}
        try check(biharmonicError<harmonicError*0.15 && biharmonicError/Double(curveN)<0.001,"Biharmonic correction continues curved lighting: harmonic MAE=\(harmonicError/Double(curveN)), biharmonic MAE=\(biharmonicError/Double(curveN))")
        var fixedBoundary=true
        for i in 0..<cw*ch where !holes[i] {for c in 0..<4 where biharmonic[i*4+c] != incomplete[i*4+c] {fixedBoundary=false}}
        try check(fixedBoundary,"Biharmonic solver preserves known boundary pixels exactly")
        try check(biharmonic.allSatisfy{$0.isFinite},"Biharmonic correction remains finite at a strong unknown-boundary discontinuity")
        let automatic=try renderer.repairProcessor.findSource(for:stroke,in:source)
        try check(automatic.x>=0 && automatic.x<=1 && automatic.y>=0 && automatic.y<=1,"Automatic sampling finds a valid source")
        try check(try renderer.repairProcessor.findSource(for:stroke,in:source)==automatic,"Automatic sampling is deterministic")
        let alternate=try renderer.repairProcessor.findSource(for:stroke,in:source,variant:1)
        try check(alternate != automatic,"Refresh offers another source")
        var edits=EditState();edits.repairs=[stroke]
        let data=try JSONEncoder().encode(edits)
        try check(try JSONDecoder().decode(EditState.self,from:data)==edits,"Repairs survive settings round trip")
        edits.disabledSections.insert(.repairs)
        try check(edits.renderingState.repairs.isEmpty && edits.repairs.count==1,"Repair master eye preserves parameters")
        let encoded=try JSONEncoder().encode(EditState())
        var old=try JSONSerialization.jsonObject(with:encoded) as! [String:Any];old.removeValue(forKey:"repairs")
        try check(try JSONDecoder().decode(EditState.self,from:JSONSerialization.data(withJSONObject:old)).repairs.isEmpty,"Old projects default to no repairs")
        let model=EditorModel(loadWorkspace:false)
        let png=try renderer.exportPNG(source:source,edits:.init())
        try model.load(data:png,name:"repair.png")
        model.edits.repairs=[stroke];model.commit();model.undo()
        try check(model.edits.repairs.isEmpty,"Undo removes a repair")
        model.redo();try check(model.edits.repairs.count==1,"Redo restores the repair")
        model.cancelEditing();try check(model.edits.repairs.isEmpty,"Cancel restores pre-repair checkpoint")
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent("LumaLab-Repair-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true);defer {try? FileManager.default.removeItem(at:temp)}
        let file=temp.appendingPathComponent("repair.png");try png.write(to:file);model.sourceURL=file
        model.edits.repairs=[stroke];model.commit();model.finishEditing()
        try check(try PhotoSettingsStore.read(for:file,data:png)?.edits.repairs==[stroke],"Done persists Repair parameters to non-DNG Sidecar")
        try check(try Data(contentsOf:file)==png,"PNG repair saving never changes the original file")
        model.renderWork?.cancel()
        return "Repair checks passed: \(count) assertions (Clone, Heal illumination, alpha, auto source, continuous stroke, cache, persistence and Undo/Cancel). Curved-light correction MAE harmonic=\(harmonicError/Double(curveN)), biharmonic=\(biharmonicError/Double(curveN))."
    }
    static func benchmark() throws -> String {
        let engine=ImagePipeline(),size=CGSize(width:7452,height:4973)
        let source=CIFilter(name:"CICheckerboardGenerator",parameters:["inputColor0":CIColor(red:0.22,green:0.3,blue:0.4),"inputColor1":CIColor(red:0.24,green:0.32,blue:0.42),"inputWidth":12,"inputSharpness":1])!.outputImage!.cropped(to:CGRect(origin:.zero,size:size))
        func materialize(_ edits:EditState,limit:CGFloat?) throws {
            try autoreleasepool {
                let output=try engine.render(source:source,edits:edits,maxDimension:limit)
                guard let data=output.dataProvider?.data,CFDataGetLength(data)>0 else {throw Failure(message:"Benchmark materialization failed")}
            }
        }
        var report:[[String:Any]]=[]
        for count in [1,20,100] {
            var edits=EditState()
            for i in 0..<count {
                var s=RepairStroke();s.radius=0.003;s.points=[UnitPoint2D(x:0.1+Double(i%10)*0.08,y:0.1+Double(i/10)*0.08)];s.source=UnitPoint2D(x:s.anchor.x+0.035,y:s.anchor.y+0.035)
                edits.repairs.append(s)
            }
            var begin=ProcessInfo.processInfo.systemUptime
            try materialize(edits,limit:1600)
            let first=(ProcessInfo.processInfo.systemUptime-begin)*1000
            var cached:[Double]=[]
            for _ in 0..<5 {
                begin=ProcessInfo.processInfo.systemUptime
                try materialize(edits,limit:1600)
                cached.append((ProcessInfo.processInfo.systemUptime-begin)*1000)
            }
            edits.repairs[count-1].source.x+=0.002
            begin=ProcessInfo.processInfo.systemUptime
            try materialize(edits,limit:1600)
            let change=(ProcessInfo.processInfo.systemUptime-begin)*1000
            begin=ProcessInfo.processInfo.systemUptime
            try materialize(edits,limit:nil)
            let full=(ProcessInfo.processInfo.systemUptime-begin)*1000
            begin=ProcessInfo.processInfo.systemUptime
            _=try engine.repairProcessor.findSource(for:edits.repairs.last!,in:source)
            let matching=(ProcessInfo.processInfo.systemUptime-begin)*1000
            edits.repairs[0].source.y+=0.002
            begin=ProcessInfo.processInfo.systemUptime
            try materialize(edits,limit:1600)
            let changeFirst=(ProcessInfo.processInfo.systemUptime-begin)*1000
            report.append(["strokes":count,"initial_preview_ms":first,"cached_preview_median_ms":cached.sorted()[2],"change_last_source_ms":change,"change_first_source_ms":changeFirst,"automatic_source_search_ms":matching,"full_resolution_render_ms":full])
        }
        return String(data:try JSONSerialization.data(withJSONObject:["width":7452,"height":4973,"radius_fraction":0.003,"material":"generated low-contrast checkerboard, small isolated Heal strokes; all outputs materialized through CGDataProvider with autoreleasepool","results":report],options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!
    }
}
