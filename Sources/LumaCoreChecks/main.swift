import Foundation
import LumaDomain

// Runs without AppKit, Core Image, Vision, or any display service.
var count = 0
func check(_ condition: Bool, _ label: String) {
    guard condition else { fatalError("Shared Core check failed: " + label) }
    count += 1
}
let stroke = [UnitPoint2D(x: 0.35, y: 0.3), UnitPoint2D(x: 0.65, y: 0.3)]
let width = 200, height = 100
let mask = PortableBrush.raster(strokes: [stroke], width: width, height: height, diameterFraction: 0.4, feather: 0.75)
check(mask[30*width+70] == 255, "brush center in top-left coordinates")
check(mask[70*width+70] == 0, "brush does not mirror vertically")
check(mask[30*width+100] == 255, "continuous stroke has no gaps")
check(mask[40*width+100] > mask[47*width+100] && mask[47*width+100] > 0, "feather continuously decreases inside radius")
check(mask[51*width+100] == 0, "brush stays inside indicated radius")
check(PortableBrush.raster(strokes: [stroke,stroke], width: width, height: height, diameterFraction: 0.4, feather: 0.75) == mask, "repainting never builds up")
let raster = try PortableMaskRaster(width: width, height: height, pixels: mask, modelID: "shared-core-fixture")
check(try JSONDecoder().decode(PortableMaskRaster.self, from: JSONEncoder().encode(raster)) == raster, "portable coverage codec")
var edits = EditState()
var automatic = LocalMask(name: "fixture", kind: .automatic); automatic.raster = raster; automatic.adjustments.exposure = 1
var erase = MaskComponent(kind: .brush, operation: .subtract); erase.strokes = [stroke]; automatic.components = [erase]
edits.masks = [automatic]
var repair = RepairStroke(); repair.points = stroke; edits.repairs = [repair]
check(try JSONDecoder().decode(EditState.self, from: JSONEncoder().encode(edits)) == edits, "full shared edit schema round trip")
let sidecar = SidecarDocument(sourceSHA256: "fixture", sourceFilename: "photo.png", edits: edits, history: [edits])
check(try JSONDecoder().decode(SidecarDocument.self, from: JSONEncoder().encode(sidecar)).edits == edits, "shared sidecar schema")
let old = Data("{\"name\":\"legacy\",\"kind\":\"brush\"}".utf8)
let legacy = try JSONDecoder().decode(LocalMask.self, from: old)
check(legacy.brushVersion == 1 && legacy.raster == nil, "legacy masks retain their old raster algorithm")
let tone = EngineColor.transform(0.4, 0.5, 0.6, edits: .init())
check(abs(tone.0-0.4) < 0.0001 && abs(tone.1-0.5) < 0.0001 && abs(tone.2-0.6) < 0.0001, "portable neutral color transform")
let dimension = PortableHealing.correctionSize(width: 10000, height: 20, radius: 2)
check(dimension.1 >= 10 && dimension.0 * dimension.1 <= 530000, "thin repair retains sampling within bounded memory")
var cubeText="LUT_3D_SIZE 2\n"
for b in 0...1 {for g in 0...1 {for r in 0...1 {cubeText+="\(b) \(g) \(r)\n"}}}
let cube=try CubeLUT(text:cubeText,name:"portable")
let mapped=cube.apply(0.2,0.4,0.8)
check(abs(mapped.0-0.8)<0.0001 && abs(mapped.2-0.2)<0.0001,"portable Cube LUT interpolation")
check(abs(PortableStack.sigmaClippedMean([0.2,0.2,0.21,0.19,1])-0.2)<0.005,"portable Sigma clipping")
var edge=EdgeBrushStroke();edge.points=[UnitPoint2D(x:0.25,y:0.5)];edge.color=[1,0,0];edge.diameter=2;edge.feather=0
var colors=[UInt8](repeating:255,count:64*32*4)
for y in 0..<32 {for x in 0..<64 {let i=(y*64+x)*4;colors[i]=x<32 ? 255:0;colors[i+1]=0;colors[i+2]=x<32 ? 0:255}}
let connected=EdgeAwareBrush.coverage(edge,rgba:colors,width:64,height:32)
check(connected[16*64+16]>250 && connected[16*64+48]==0,"portable color-connected Brush")
automatic.edgeStrokes=[edge];automatic.groupID=UUID();automatic.overlayColor=[0,1,0];edits.masks=[automatic];edits.lut.cube=cube
check(try JSONDecoder().decode(EditState.self,from:JSONEncoder().encode(edits))==edits,"new fields preserve shared schema round trip")
check(try PortableSegmentation.unitNHWCTensor(Data([255,0,128,255,0,255,64,255]),width:2,height:1)==[1,0,Float(128)/255,0,1,Float(64)/255],"portable NHWC RGB input normalization")
check(try PortableSegmentation.planarNHWCLogits([1,2,3,4,5,6],width:2,height:1,channels:3)==[1,4,2,5,3,6],"portable NHWC semantic output transposition")
print("Shared Core checks passed: \(count) assertions; Foundation and portable C++ only.")
