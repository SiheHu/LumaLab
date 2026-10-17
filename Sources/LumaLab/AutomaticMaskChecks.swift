import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
import CoreImage
import LumaDomain

/// Persistence, portable preprocessing/reprojection, and actual bundled ONNX
/// inference checks. Real-photo quality observations are documented separately.
enum AutomaticMaskChecks {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static func run() throws -> String {
        var count = 0
        func check(_ value: Bool, _ name: String) throws { guard value else { throw Failure(message:name) }; count += 1 }
        func rejects(_ name: String, _ operation: () throws -> Void) throws {
            var rejected = false
            do { try operation() } catch { rejected = true }
            try check(rejected,name)
        }
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let flat = try PortableMaskRaster(width:64,height:32,pixels:Data(repeating:255,count:2048),modelID:"portable-check")
        let flatJSON = try encoder.encode(flat)
        try check(try decoder.decode(PortableMaskRaster.self,from:flatJSON) == flat,"Uniform raster round-trips")
        try check(flatJSON.count < 220,"Uniform raster uses bounded RLE rather than raw pixels")
        let noise = try PortableMaskRaster(width:8,height:8,pixels:Data((0..<64).map{UInt8($0*3)}),modelID:"noise")
        try check(try decoder.decode(PortableMaskRaster.self,from:encoder.encode(noise)) == noise,"Noncompressible raster round-trips as gray8")
        try rejects("Dimension mismatch is rejected") { _ = try PortableMaskRaster(width:2,height:2,pixels:Data([0]),modelID:"") }
        try rejects("Oversized raster is rejected") { _ = try PortableMaskRaster(width:Int.max,height:2,pixels:Data(),modelID:"") }
        try rejects("Empty raster is rejected") { _ = try PortableMaskRaster(width:0,height:1,pixels:Data(),modelID:"") }
        func encoded(_ encoding:String,_ pixels:Data,_ version:Int = 1) throws -> Data {
            try JSONSerialization.data(withJSONObject:["version":version,"width":2,"height":2,"modelID":"invalid-test","encoding":encoding,"pixels":pixels.base64EncodedString()])
        }
        try rejects("Zero-length RLE is rejected") { _ = try decoder.decode(PortableMaskRaster.self,from:encoded("rle8-le32",Data([255,0,0,0,0]))) }
        try rejects("RLE expansion beyond dimensions is rejected") { _ = try decoder.decode(PortableMaskRaster.self,from:encoded("rle8-le32",Data([255,5,0,0,0]))) }
        try rejects("Truncated RLE is rejected") { _ = try decoder.decode(PortableMaskRaster.self,from:encoded("rle8-le32",Data([255,4]))) }
        try rejects("Unknown encoding is rejected") { _ = try decoder.decode(PortableMaskRaster.self,from:encoded("future",Data([0,0,0,0]))) }
        try rejects("Unknown schema version is rejected") { _ = try decoder.decode(PortableMaskRaster.self,from:encoded("gray8",Data([0,0,0,0]),2)) }
        let tensor = try PortableSegmentation.normalizedRGBATensor(Data([255,0,128,255,0,255,64,255]),width:2,height:1)
        try check(tensor.count == 6,"RGB normalization returns planar NCHW")
        try check(abs(tensor[0]-(1-0.485)/0.229)<0.00001 && abs(tensor[1]-(0-0.485)/0.229)<0.00001,"Red plane matches model author normalization")
        try check(abs(tensor[2]-(0-0.456)/0.224)<0.00001 && abs(tensor[3]-(1-0.456)/0.224)<0.00001,"Green plane preserves pixel order")
        try rejects("Incomplete RGB input is rejected") { _ = try PortableSegmentation.normalizedRGBATensor(Data([255]),width:1,height:1) }
        let mask = try PortableSegmentation.categoricalCoverage(logits:[3,0,0,3,0,3,3,0],width:2,height:2,channels:2,selected:[1])
        try check(mask == Data([0,255,255,0]),"Semantic class selection is correct and uniform inside classes")
        try rejects("Nonfinite model output is rejected") { _ = try PortableSegmentation.categoricalCoverage(logits:[Float.nan],width:1,height:1,channels:1,selected:[0]) }
        try check(PortableSegmentation.faceLabels(for:.skin).contains(1) && !PortableSegmentation.faceLabels(for:.skin).contains(17),"Skin and hair are distinct semantic classes")
        try check(PortableSegmentation.faceLabels(for:.eyes)==[4,5],"Both eyes are selected")
        let placed = try PortableSegmentation.place(Data([255]),inputWidth:1,inputHeight:1,x:0.5,y:0,cropWidth:0.5,cropHeight:0.5,width:4,height:4)
        try check(placed == Data([0,0,255,255,0,0,255,255,0,0,0,0,0,0,0,0]),"Face crop reprojection uses top-left coordinates")
        let identity = try PortableSegmentation.place(mask,inputWidth:2,inputHeight:2,x:0,y:0,cropWidth:1,cropHeight:1,width:2,height:2)
        try check(identity == mask,"Identity reprojection preserves orientation exactly")
        try rejects("Invalid crop is rejected") { _ = try PortableSegmentation.place(mask,inputWidth:2,inputHeight:2,x:0.9,y:0,cropWidth:0.5,cropHeight:1,width:4,height:4) }
        // Exercise the real rendering adapter: top-left saved coverage must
        // drive exactly the same pixels in editing and the highlight overlay.
        let engine = ImagePipeline()
        let source = CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 80, height: 40))
        var automatic = LocalMask(name: "semantic adapter fixture", kind: .automatic)
        automatic.raster = try PortableMaskRaster(width: 4, height: 2, pixels: Data([255,255,0,0,0,0,0,0]), modelID: "adapter-test")
        automatic.adjustments.exposure = 2
        var edits = EditState(); edits.masks = [automatic]
        let rendered = try engine.render(source: source, edits: edits)
        let data = [UInt8](rendered.dataProvider!.data! as Data)
        func red(_ x: Int, _ y: Int) -> Int { Int(data[y*rendered.bytesPerRow+x*4]) }
        try check(red(8, 5) > red(70, 5)+20 && abs(red(8, 35)-red(70, 35)) <= 1, "Saved mask applies to top-left photo pixels without mirroring: top=\(red(8,5))/\(red(70,5)), bottom=\(red(8,35))/\(red(70,35))")
        let overlay = try engine.selectionOverlay(automatic, source: source, maxDimension: 80)
        let overlayData = [UInt8](overlay.dataProvider!.data! as Data)
        try check(overlayData[5*overlay.bytesPerRow+8*4+3] > 100 && overlayData[35*overlay.bytesPerRow+8*4+3] == 0, "Overlay follows identical saved semantic coverage")
        let roundTrip = try decoder.decode(EditState.self, from: encoder.encode(edits))
        try check(roundTrip == edits, "Semantic mask is preserved by edit-state persistence")
        var subtract = MaskComponent(kind: .brush, operation: .subtract); subtract.brushSize = 0.3; subtract.feather = 0; subtract.strokes = [[UnitPoint2D(x: 0.15, y: 0.25)]]
        edits.masks[0].components = [subtract]
        let refined = try engine.render(source: source, edits: edits)
        let refinedData = [UInt8](refined.dataProvider!.data! as Data)
        try check(Int(refinedData[10*refined.bytesPerRow+12*4]) < red(12, 10)-20, "Subtract Brush refines semantic mask at the pointer position")
        // Actually load both shipped model weights through the portable C ABI.
        // A small synthetic photo is sufficient for a deterministic contract test;
        // this does not claim photographic accuracy from a synthetic fixture.
        var rgb = [UInt8](repeating:255,count:64*64*4)
        for y in 0..<64 { for x in 0..<64 {
            let i=(y*64+x)*4
            rgb[i]=y<32 ? 100:60;rgb[i+1]=y<32 ? 170:100;rgb[i+2]=y<32 ? 230:50
        }}
        let provider = CGDataProvider(data:Data(rgb) as CFData)!
        let image = CGImage(width:64,height:64,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:256,
                            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent)!
        let sky = try AutomaticONNXSession(name:"skyseg-fp16").predict(image)
        try check(sky.width==320 && sky.height==320 && sky.channels==1,"Bundled sky model executes and reports expected dimensions")
        try check(sky.values.allSatisfy{$0.isFinite && $0 >= -0.01 && $0 <= 1.01},"Sky output is finite sigmoid coverage within FP16 roundoff")
        if AutomaticONNXSession.modelURL(name:"face-parsing-resnet18") != nil {
            let face = try AutomaticONNXSession(name:"face-parsing-resnet18").predict(image)
            try check(face.width==512 && face.height==512 && face.channels==19,"Optional face model executes with 19 semantic classes")
            try check(face.values.allSatisfy{$0.isFinite},"Face logits contain no nonfinite values")
        }
        let body=try AutomaticONNXSession(name:"selfie-skin").predict(image)
        try check(body.width==256 && body.height==256 && body.channels==6,"All Skin model executes through NHWC C ABI and returns planar six-class logits")
        try check(body.values.allSatisfy{$0.isFinite},"All Skin logits are finite")
        let rw=32,rh=24,plane=rw*rh
        var lensLogits=[Float](repeating:0,count:plane*19),lensRGB=[UInt8](repeating:255,count:plane*4)
        for y in 0..<rh {for x in 0..<rw {
            let i=y*rw+x,glass=x>=10 && x<22 && y>=5 && y<19
            lensLogits[(glass ? 6:1)*plane+i]=10
            for (c,value) in [180,130,100].enumerated() {lensRGB[i*4+c]=UInt8(value)}
            if x==10 && glass {for c in 0..<3 {lensRGB[i*4+c]=10}}
        }}
        let eyePolygon=[UnitPoint2D(x:0.4,y:0.4),.init(x:0.6,y:0.4),.init(x:0.6,y:0.6),.init(x:0.4,y:0.6)]
        let skin=try PortableSegmentation.skinCoverage(logits:lensLogits,width:rw,height:rh,rgba:Data(lensRGB),eyePolygons:[eyePolygon])
        try check(skin[7*rw+15]>240,"Skin includes visible skin behind a transparent lens")
        try check(skin[7*rw+10]==0,"Skin refinement preserves a dark frame instead of filling all glasses")
        try check(skin[12*rw+16]==0,"Skin refinement excludes the actual eye opening behind glasses")
        lensLogits[4*plane]=20
        let eye=try PortableSegmentation.eyeCoverage(logits:lensLogits,width:rw,height:rh,polygons:[eyePolygon])
        try check(eye[0]==0 && eye[12*rw+16]==255,"Eye Landmarks reject distant false positives while retaining eyes under transparent lenses")
        var six=[Float](repeating:0,count:6*4)
        for (i,c) in [2,3,4,5].enumerated() {six[c*4+i]=10}
        let sixMask=try PortableSegmentation.skinCoverage(logits:six,width:4,height:1,channels:6,rgba:Data(repeating:180,count:16),eyePolygons:[],faceRegions:[])
        try check(sixMask==Data([255,255,0,0]),"All Skin includes body and face skin while excluding clothes and accessories")
        if let path=ProcessInfo.processInfo.environment["LUMALAB_MASK_PHOTO"],let folder=ProcessInfo.processInfo.environment["LUMALAB_MASK_OUTPUT"] {
            let data=try Data(contentsOf:URL(fileURLWithPath:path))
            let photo=try PhotoIO.decode(data:data,fileExtension:URL(fileURLWithPath:path).pathExtension)
            let input=try engine.render(source:photo.image,edits:.init(),maxDimension:2048)
            let output=URL(fileURLWithPath:folder,isDirectory:true);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            for kind:AutomaticMaskKind in [.skin,.eyes,.allSkin] {
                let results=try AutomaticMaskService.shared.generate(kind,image:input)
                try check(!results.isEmpty,"Real photo produces \(kind.rawValue) Coverage")
                for (index,result) in results.enumerated() {
                    var mask=LocalMask(name:result.name,kind:.automatic);mask.raster=result.raster
                    let cg=try engine.coveragePreview(mask,source:CIImage(cgImage:input),maxDimension:2048)
                    let url=output.appendingPathComponent("\(kind.rawValue)-\(index).png")
                    let dest=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
                    CGImageDestinationAddImage(dest,cg,nil);guard CGImageDestinationFinalize(dest) else {throw Failure(message:"write mask fixture")}
                }
            }
        }
        return "Automatic Mask checks passed: \(count)"
    }
}
