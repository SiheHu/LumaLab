import Foundation
import CoreImage
import CoreGraphics
import AppKit
import LumaDomain

/// Shared preprocessing/blending invariants plus one actual LaMa inference.
enum ContentRepairChecks {
    struct Failure: LocalizedError { let message:String; var errorDescription:String? {message} }
    static func run() throws -> String {
        var count = 0
        func check(_ value:Bool,_ message:String) throws {guard value else {throw Failure(message:message)};count+=1}
        func rejects(_ message:String,_ operation:() throws ->Void)throws{var rejected=false;do{try operation()}catch{rejected=true};try check(rejected,message)}
        let alphaSource = Data([80,40,20,128, 9,8,7,0, 31,63,127,255])
        let straight = PortableInpainting.straightRGBA(fromPremultiplied:alphaSource)
        try check(straight == Data([159,80,40,128, 0,0,0,0, 31,63,127,255]),"Model input unpremultiplies partial alpha and clears transparent RGB")
        let back = [UInt8](PortableInpainting.premultipliedRGBA(fromStraight:straight))
        try check(Array(back[0..<4]) == [80,40,20,128],"Premultiplication round-trip preserves representative partial alpha")
        try check(Array(back[4..<8]) == [0,0,0,0],"Alpha-zero output cannot leak hidden RGB")
        try check(Array(back[8..<12]) == [31,63,127,255],"Opaque alpha conversion is byte-exact")
        try check([UInt8](straight).enumerated().filter{$0.offset%4==3}.map{$0.element} == [128,0,255],"Alpha channel never changes during model input conversion")
        let w=64,h=40
        var original=[UInt8](repeating:255,count:w*h*4),mask=[UInt8](repeating:0,count:w*h)
        for p in 0..<w*h {original[p*4]=102;original[p*4+1]=153;original[p*4+2]=204;original[p*4+3]=187}
        for y in 14..<26 {for x in 26..<38 {let p=y*w+x;mask[p]=255;for c in 0..<3 {original[p*4+c]=0}}}
        func outsideUnchanged(_ result:[UInt8]) -> Bool {
            for p in 0..<(w*h) where mask[p] == 0 {
                for c in 0..<4 where result[p*4+c] != original[p*4+c] { return false }
            }
            return true
        }
        let source=Data(original),selection=Data(mask)
        let prepared=try PortableInpainting.prepare(rgba:source,mask:selection,width:w,height:h)
        try check(prepared.layout.width==512 && prepared.layout.height==320 && prepared.layout.offsetY==96,"Inpainting preserves aspect ratio with centered padding")
        try check(prepared.image.count==3*512*512 && prepared.mask.count==512*512,"LaMa input dimensions are fixed 512 NCHW")
        try check(prepared.image.allSatisfy{$0.isFinite && $0>=0 && $0<=1},"LaMa RGB input uses unit range")
        try check(prepared.mask.allSatisfy{$0==0 || $0==1},"LaMa receives a binary remove mask")
        try check(prepared.mask[0]==0 && abs(prepared.image[0]-102.0/255)<0.0001,"Padding reflects context and never becomes removal mask")
        var large=[UInt8](repeating:0,count:2048*32)
        for x in 0..<2048 {large[15*2048+x]=255}
        let wire=try PortableInpainting.prepare(rgba:Data(repeating:127,count:2048*32*4),mask:Data(large),width:2048,height:32)
        try check(wire.mask.filter{$0==1}.count>=512,"Conservative mask reduction retains a one-pixel wire")
        try rejects("Invalid source byte count is rejected"){_ = try PortableInpainting.prepare(rgba:Data([0]),mask:Data([255]),width:1,height:1)}
        try rejects("Invalid mask byte count is rejected"){_ = try PortableInpainting.prepare(rgba:Data([0,0,0,255]),mask:Data(),width:1,height:1)}
        try rejects("Excessive dimensions are rejected before allocation"){_ = try PortableInpainting.prepare(rgba:Data(),mask:Data(),width:Int.max,height:2)}
        var predicted=[Float](repeating:220,count:3*512*512)
        for p in 0..<512*512 {predicted[512*512+p]=120;predicted[2*512*512+p]=80}
        let composite=[UInt8](try PortableInpainting.composite(output:predicted,onto:source,mask:selection,width:w,height:h,layout:prepared.layout))
        let target=(20*w+32)*4
        try check(Array(composite[target..<target+3])==[220,120,80],"Predicted NCHW RGB maps to the selected native pixel")
        try check(composite[target+3]==187,"Inpainting retains source alpha")
        try check(outsideUnchanged(composite),"Unselected bytes are exact")
        var feather=mask;feather[20*w+32]=128
        let unblended=[UInt8](try PortableInpainting.composite(output:predicted,onto:source,mask:Data(feather),width:w,height:h,layout:prepared.layout))
        try check(unblended[target]==220,"Default prediction leaves feather/opacity blending to the renderer exactly once")
        let blended=[UInt8](try PortableInpainting.composite(output:predicted,onto:source,mask:Data(feather),width:w,height:h,layout:prepared.layout,applyCoverage:true))
        try check(blended[target]==110,"Optional standalone coverage blending applies the provided feather once")
        predicted[0] = .nan
        try rejects("Nonfinite prediction is rejected"){_ = try PortableInpainting.composite(output:predicted,onto:source,mask:selection,width:w,height:h,layout:prepared.layout)}
        // Exercise the real, bundled model with a synthetic black obstruction on
        // uniform RGB. This verifies execution and useful removal, not equivalence
        // to Camera Raw or quality on every photographic object.
        let generated=[UInt8](try ContentRepairService.shared.process(rgba:source,mask:selection,width:w,height:h))
        let expected=[102,153,204]
        let error=(0..<3).reduce(0){$0+abs(Int(generated[target+$1])-expected[$1])}
        try check(error<45,"Actual LaMa model reconstructs the synthetic obstruction using context (error \(error))")
        try check(generated[target+3]==187,"Actual LaMa preserves source alpha")
        try check(outsideUnchanged(generated),"Actual inference cannot change pixels outside the mask")
        let noOp=try ContentRepairService.shared.process(rgba:source,mask:Data(repeating:0,count:w*h),width:w,height:h)
        try check(noOp==source,"Empty mask is a byte-exact no-op")
        let provider=CGDataProvider(data:source as CFData)!
        let bitmap=CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent)!
        let photograph=CIImage(cgImage:bitmap),engine=ImagePipeline()
        var stroke=RepairStroke();stroke.mode = .inpaint;stroke.radius=0.25;stroke.feather=0;stroke.points=[UnitPoint2D(x:0.5,y:0.5)]
        var edits=EditState();edits.repairs=[stroke]
        let actual=try engine.render(source:photograph,edits:edits)
        let raw=[UInt8](actual.dataProvider!.data! as Data),offset=20*actual.bytesPerRow+32*4
        try check(raw[offset]>50 && raw[offset+1]>70,"Real renderer applies local model reconstruction at the Brush target")
        try check(abs(Int(raw[offset+3])-187)<=1,"Real renderer preserves alpha during local model compositing")
        let baseline=try engine.render(source:photograph,edits:.init())
        let baselineRaw=[UInt8](baseline.dataProvider!.data! as Data)
        try check((0..<4).allSatisfy{abs(Int(raw[3*actual.bytesPerRow+3*4+$0])-Int(baselineRaw[3*baseline.bytesPerRow+3*4+$0]))<=1},"Real renderer leaves pixels outside the Brush unchanged")
        edits.repairs[0].opacity=0.5
        let partial=try engine.render(source:photograph,edits:edits)
        let half=[UInt8](partial.dataProvider!.data! as Data)
        try check(half[offset]>10 && half[offset]<raw[offset],"Content removal opacity blends one time after cached inference")
        try check(try JSONDecoder().decode(EditState.self,from:JSONEncoder().encode(edits))==edits,"Content removal mode survives edit-state serialization")
        // A photographic-style curved illumination field, fine texture, and a
        // strong edge exercise the complete renderer. High Feather used to
        // blend the black obstruction back despite successful model inference.
        let fw=128,fh=96
        var clean=[UInt8](repeating:255,count:fw*fh*4)
        for y in 0..<fh {for x in 0..<fw {
            let illumination=75.0+0.004*Double(x*x)+0.002*Double(y*y)+(x>=72 ? 55.0:0)+3*sin(Double(x+y)*0.7)
            for c in 0..<3 {clean[(y*fw+x)*4+c]=UInt8(min(255,max(0,illumination+Double(c)*12)))}
        }}
        var dirty=clean
        for y in 39..<57 {for x in 35..<45 {for c in 0..<3 {dirty[(y*fw+x)*4+c]=2}}}
        func fixtureImage(_ bytes:[UInt8])->CIImage {
            let provider=CGDataProvider(data:Data(bytes) as CFData)!
            let cg=CGImage(width:fw,height:fh,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:fw*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent)!
            return CIImage(cgImage:cg)
        }
        let fixture=fixtureImage(dirty)
        var soft=RepairStroke();soft.mode = .inpaint;soft.radius=10.0/Double(fh);soft.feather=1
        soft.points=[UnitPoint2D(x:40.0/Double(fw),y:43.0/Double(fh)),UnitPoint2D(x:40.0/Double(fw),y:53.0/Double(fh))]
        soft.algorithmVersion=2
        var fixtureEdits=EditState();fixtureEdits.repairs=[soft]
        let legacy=try engine.render(source:fixture,edits:fixtureEdits)
        soft.algorithmVersion=3;fixtureEdits.repairs=[soft]
        let improved=try engine.render(source:fixture,edits:fixtureEdits)
        let reference=try engine.render(source:fixtureImage(clean),edits:.init())
        let untouched=try engine.render(source:fixture,edits:.init())
        func bytes(_ image:CGImage)->[UInt8] {[UInt8](image.dataProvider!.data! as Data)}
        let oldBytes=bytes(legacy),newBytes=bytes(improved),truth=bytes(reference),bad=bytes(untouched)
        func defectError(_ values:[UInt8])->Double {
            var sum=0.0,n=0
            for y in 39..<57 {for x in 35..<45 {for c in 0..<3 {let i=y*reference.bytesPerRow+x*4+c;sum+=abs(Double(values[i])-Double(truth[i]));n+=1}}}
            return sum/Double(n)
        }
        let oldError=defectError(oldBytes),newError=defectError(newBytes),badError=defectError(bad)
        try check(newError<oldError*0.65 && newError<badError*0.35,"High-Feather Inpainting removes the full painted obstruction on curved textured lighting: v2=\(oldError), v3=\(newError), original=\(badError)")
        // Strong edge outside the Brush is an exact invariant, not an inferred
        // success from a flat reconstruction fixture.
        var edgeUnchanged=true
        for y in 0..<fh {for x in 76..<fw {for c in 0..<4 {let i=y*reference.bytesPerRow+x*4+c;if newBytes[i] != bad[i] {edgeUnchanged=false}}}}
        try check(edgeUnchanged,"High-Feather Inpainting preserves the unselected strong edge and texture")
        var oldAgain=soft;oldAgain.algorithmVersion=2;fixtureEdits.repairs=[oldAgain]
        try check(bytes(try engine.render(source:fixture,edits:fixtureEdits))==oldBytes,"Legacy v2 Inpainting remains reproducible after v3 rendering")
        if let outputPath=ProcessInfo.processInfo.environment["LUMALAB_REPAIR_FIXTURES"] {
            let directory=URL(fileURLWithPath:outputPath,isDirectory:true)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            for (name,cg) in [("inpaint-original",untouched),("inpaint-reference",reference),("inpaint-v2",legacy),("inpaint-v3",improved)] {
                let representation=NSBitmapImageRep(cgImage:cg)
                try representation.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent(name+".png"))
            }
            try JSONSerialization.data(withJSONObject:["metric":"Mean absolute sRGB byte error on the black obstruction; actual bundled LaMa through full renderer", "v2":oldError,"v3":newError,"original":badError],options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("inpaint-fixture-metrics.json"))
            // Optional public photographic sample. Its ground truth is unknown,
            // so emit before/after for visual review without inventing a score.
            if let photoPath=ProcessInfo.processInfo.environment["LUMALAB_REPAIR_PHOTO"],let photo=CIImage(contentsOf:URL(fileURLWithPath:photoPath)) {
                var removal=RepairStroke();removal.mode = .inpaint;removal.radius=0.15;removal.feather=0.5
                removal.points=[UnitPoint2D(x:0.52,y:0.49),UnitPoint2D(x:0.52,y:0.83),UnitPoint2D(x:0.45,y:0.89),UnitPoint2D(x:0.62,y:0.88)]
                var edits=EditState()
                for version in [2,3] {
                    removal.algorithmVersion=version;edits.repairs=[removal]
                    let output=try engine.render(source:photo,edits:edits)
                    try NSBitmapImageRep(cgImage:output).representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent("photographic-inpaint-v\(version).png"))
                }
                let before=try engine.render(source:photo,edits:.init())
                try NSBitmapImageRep(cgImage:before).representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent("photographic-original.png"))
            }
        }
        return "Content repair checks passed: \(count); high-Feather obstruction MAE v2=\(oldError), v3=\(newError)."
    }
}
