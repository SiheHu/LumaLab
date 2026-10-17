import LumaDomain
import Foundation
import CoreImage
import ImageIO

@MainActor enum EnhancementChecks {
    static func run() throws -> String {
        var count=0
        func check(_ ok:Bool,_ name:String) throws {guard ok else {throw NSError(domain:"EnhancementChecks",code:count,userInfo:[NSLocalizedDescriptionKey:name])};count+=1}
        let engine=ImagePipeline(),space=CGColorSpace(name:CGColorSpace.sRGB)!
        let source=CIImage(bitmapData:Data([64,128,192,255]),bytesPerRow:4,size:CGSize(width:1,height:1),format:.RGBA8,colorSpace:space)
            .clampedToExtent().cropped(to:CGRect(x:0,y:0,width:64,height:32))
        let metadata:[String:Any]=[kCGImagePropertyGPSDictionary as String:[kCGImagePropertyGPSLatitude as String:31.2,kCGImagePropertyGPSLatitudeRef as String:"N",kCGImagePropertyGPSLongitude as String:121.5,kCGImagePropertyGPSLongitudeRef as String:"E"],kCGImagePropertyTIFFDictionary as String:[kCGImagePropertyTIFFMake as String:"LumaLabFixture"],kCGImagePropertyExifDictionary as String:[kCGImagePropertyExifISOSpeedRatings as String:[200]]]
        for format in OutputFormat.allCases {
            var options=ExportOptions();options.format=format
            let clean=try engine.export(source:source,edits:.init(),options:options,metadata:metadata)
            let cleanSource=CGImageSourceCreateWithData(clean as CFData,nil)!
            let properties=CGImageSourceCopyPropertiesAtIndex(cleanSource,0,nil)! as NSDictionary
            try check(properties[kCGImagePropertyGPSDictionary] == nil,"GPS removed from encoded \(format)")
            let tiff=properties[kCGImagePropertyTIFFDictionary] as? NSDictionary
            let exif=properties[kCGImagePropertyExifDictionary] as? NSDictionary
            try check(tiff?[kCGImagePropertyTIFFMake] as? String == "LumaLabFixture" || exif?[kCGImagePropertyExifISOSpeedRatings] != nil,"Camera metadata survives \(format)")
            options.removeGPS=false
            let full=try engine.export(source:source,edits:.init(),options:options,metadata:metadata)
            let fullProperties=CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(full as CFData,nil)!,0,nil)! as NSDictionary
            try check(fullProperties[kCGImagePropertyGPSDictionary] != nil,"GPS retained on explicit opt-in \(format)")
            options.includeMetadata=false
            let bare=try engine.export(source:source,edits:.init(),options:options,metadata:metadata)
            let bareProperties=CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(bare as CFData,nil)!,0,nil)! as NSDictionary
            try check(bareProperties[kCGImagePropertyGPSDictionary] == nil,"All metadata off overrides GPS opt-in \(format)")
        }
        try check((metadata[kCGImagePropertyGPSDictionary as String] as? [String:Any]) != nil,"Export does not mutate original metadata")
        let cube=try engine.globalColorLUT(edits:.init(),size:17)
        let neutral=cube.apply(0.25,0.5,0.75)
        try check(abs(neutral.0-0.25)<0.001 && abs(neutral.2-0.75)<0.001,"LUT identity preserves channel and axis order")
        var state=EditState();state.adjustments.exposure=0.4;state.adjustments.temperature=7;state.hsl[5].saturation = -24
        state.curves.master=[.init(x:0,y:0),.init(x:0.5,y:0.56),.init(x:1,y:1)]
        let transformed=try engine.globalColorLUT(edits:state)
        let roundTrip=try CubeLUT(text:transformed.serialized(),name:"Roundtrip")
        let expected=try engine.render(source:source,edits:state)
        let bytes=[UInt8](expected.dataProvider!.data! as Data)
        let actual=roundTrip.apply(Double(64)/255,Double(128)/255,Double(192)/255)
        try check(zip([actual.0,actual.1,actual.2],bytes.prefix(3)).allSatisfy{abs($0-Double($1)/255)<0.025},"Exported LUT agrees with actual rendered color pipeline")
        var spatial=state;spatial.adjustments.clarity=80;spatial.adjustments.grain=90;spatial.adjustments.vignette=60;spatial.geometry.angle=30;spatial.crop = .init(x:0.2,y:0.2,width:0.5,height:0.5)
        spatial.repairs=[RepairStroke()];spatial.masks=[LocalMask()]
        try check(try engine.globalColorLUT(edits:spatial,size:17).values == engine.globalColorLUT(edits:state,size:17).values,"LUT excludes all unsupported spatial operations")
        state.disabledSections.insert(.light)
        try check(state.lutExportState.adjustments.exposure==0,"Disabled adjustments remain disabled in exported LUT")
        let full=try PortableMaskRaster(width:2,height:1,pixels:Data([255,255]),modelID:"full")
        let half=try PortableMaskRaster(width:2,height:1,pixels:Data([255,0]),modelID:"half")
        var mask=LocalMask(name:"mask",kind:.automatic);mask.raster=full
        var part=MaskComponent(kind:.automatic,operation:.intersect);part.raster=half;part.inverted=true;mask.components=[part]
        let coverage=try engine.coveragePreview(mask,source:source)
        let coverageBytes=[UInt8](coverage.dataProvider!.data! as Data)
        try check(coverageBytes[4] < 2 && coverageBytes[(coverage.width-2)*4]>250,"Component inversion happens before intersect blending")
        let model=EditorModel(loadWorkspace:false);model.source=nil;model.renderWork?.cancel();model.edits=EditState(masks:[mask]);model.history=[model.edits];model.historyIndex=0;model.selectedMaskID=mask.id
        model.duplicateComponent(id:part.id,inverted:true)
        try check(model.edits.masks[0].components.count==2 && model.edits.masks[0].components[1].id != part.id,"Duplicate creates a fresh editable component")
        try check(!model.edits.masks[0].components[1].inverted && model.edits.masks[0].components[0]==part,"Duplicate-and-invert preserves original data")
        model.undo();try check(model.edits.masks[0].components==[part],"Component duplication is one undo step")
        model.redo();try check(model.edits.masks[0].components.count==2,"Component duplication can be redone")
        let saved=try JSONDecoder().decode(EditState.self,from:JSONEncoder().encode(model.edits))
        try check(saved==model.edits,"Component inversion survives saved settings round trip")
        var options=ExportOptions();options.longEdge=32
        let estimate=try engine.estimateExport(source:source,edits:.init(),options:options,metadata:metadata)
        let encoded=try engine.export(source:source,edits:.init(),options:options,metadata:metadata)
        try check(abs(Int64(encoded.count)-estimate)<=2,"Estimate matches exact encode when output fits sample budget")
        model.cancelExportEstimate();try check(!model.estimatePending && model.exportEstimate==nil,"Closing Export clears pending estimate")
        model.autosaveWork?.cancel();model.overlayWork?.cancel();model.renderWork?.cancel();model.recoveryWork?.cancel()
        return "Enhancement checks passed: \(count) assertions (GPS, LUT fidelity, Mask components, Export estimate)."
    }
}
