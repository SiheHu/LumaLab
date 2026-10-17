import Foundation
import UniformTypeIdentifiers
import CoreGraphics
import ColorSync
import AppKit
import SwiftUI

struct ProofOptions:Equatable {
    var enabled=false
    var profile:Data?
    var name="sRGB"
    var intent=0
    var gamutWarning=false
}
enum SoftProof {
    enum Failure:LocalizedError {
        case invalidProfile,conversion
        var errorDescription:String? {self == .invalidProfile ? "无法读取这个 ICC Profile。":"这个 ICC Profile 无法用于 Soft Proofing；已保留正常预览。"}
    }
    static func render(_ image:CGImage,options:ProofOptions) throws -> CGImage {
        guard options.enabled else {return image}
        let srgb=CGColorSpace(name:CGColorSpace.sRGB)!
        guard let sourceData=(image.colorSpace ?? srgb).copyICCData(),let destinationData=srgb.copyICCData(),
              let sourceProfile=ColorSyncProfileCreate(sourceData,nil)?.takeRetainedValue(),
              let destinationProfile=ColorSyncProfileCreate(destinationData,nil)?.takeRetainedValue(),
              let proof=ColorSyncProfileCreate((options.profile ?? (destinationData as Data)) as CFData,nil)?.takeRetainedValue(),
              let provider=image.dataProvider,let data=provider.data else {throw Failure.invalidProfile}
        let intent=options.intent == 0 ? kColorSyncRenderingIntentRelative!.takeUnretainedValue():kColorSyncRenderingIntentPerceptual!.takeUnretainedValue()
        func entry(_ profile:ColorSyncProfile,_ tag:CFString,_ rendering:CFString)->[CFString:Any] {
            [kColorSyncProfile!.takeUnretainedValue():profile,kColorSyncTransformTag!.takeUnretainedValue():tag,kColorSyncRenderingIntent!.takeUnretainedValue():rendering,kColorSyncBlackPointCompensation!.takeUnretainedValue():true]
        }
        let sequence=[entry(sourceProfile,kColorSyncTransformDeviceToPCS!.takeUnretainedValue(),intent),entry(proof,kColorSyncTransformPCSToPCS!.takeUnretainedValue(),intent),entry(destinationProfile,kColorSyncTransformPCSToDevice!.takeUnretainedValue(),kColorSyncRenderingIntentRelative!.takeUnretainedValue())]
        guard let transform=ColorSyncTransformCreate(sequence as CFArray,nil)?.takeRetainedValue() else {throw Failure.conversion}
        let input=[UInt8](data as Data),w=image.width,h=image.height
        let floatInput=image.bitsPerComponent==32 && image.bitmapInfo.contains(.floatComponents)
        let sourceDepth = floatInput ? kColorSync32BitFloat:kColorSync8BitInteger
        let sourceLayout=ColorSyncDataLayout(kColorSyncAlphaPremultipliedLast.rawValue)

        let conversionOptions:CFDictionary? = nil
        var output=[UInt8](repeating:0,count:w*h*4)
        let ok=output.withUnsafeMutableBytes {dst in input.withUnsafeBytes {src in
            ColorSyncTransformConvert(transform,w,h,dst.baseAddress!,kColorSync8BitInteger,ColorSyncDataLayout(kColorSyncAlphaPremultipliedLast.rawValue),w*4,src.baseAddress!,sourceDepth,sourceLayout,image.bytesPerRow,conversionOptions)
        }}
        guard ok else {throw NSError(domain:"SoftProof",code:1,userInfo:[NSLocalizedDescriptionKey:"ICC conversion failed (source bits: \(image.bitsPerComponent))"])}
        if options.gamutWarning {
            let sequence=[entry(sourceProfile,kColorSyncTransformDeviceToPCS!.takeUnretainedValue(),kColorSyncRenderingIntentRelative!.takeUnretainedValue()),entry(proof,kColorSyncTransformGamutCheck!.takeUnretainedValue(),kColorSyncRenderingIntentRelative!.takeUnretainedValue())]
            guard let check=ColorSyncTransformCreate(sequence as CFArray,nil)?.takeRetainedValue() else {throw Failure.conversion}
            var gamut=[UInt8](repeating:0,count:w*h)
            let success=gamut.withUnsafeMutableBytes {dst in input.withUnsafeBytes {src in
                ColorSyncTransformConvert(check,w,h,dst.baseAddress!, kColorSync8BitInteger,ColorSyncDataLayout(kColorSyncAlphaNone.rawValue),w,src.baseAddress!,sourceDepth,sourceLayout,image.bytesPerRow,conversionOptions)
            }}
            guard success else {throw Failure.conversion}
            for i in 0..<w*h where gamut[i]>0 {output[i*4]=255;output[i*4+1]=0;output[i*4+2]=255}
        }
        guard let provider=CGDataProvider(data:Data(output) as CFData),let result=CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,space:srgb,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else {throw Failure.conversion}
        return result
    }
}
@MainActor extension EditorModel {
    func chooseProofProfile() {
        let panel=NSOpenPanel();panel.allowedContentTypes=[UTType(filenameExtension:"icc") ?? .data,UTType(filenameExtension:"icm") ?? .data]
        guard panel.runModal() == .OK,let url=panel.url else {return}
        do {
            let data=try Data(contentsOf:url)
            guard data.count<=16*1024*1024,ColorSyncProfileCreate(data as CFData,nil)?.takeRetainedValue() != nil else {throw SoftProof.Failure.invalidProfile}
            proofOptions.profile=data;proofOptions.name=url.deletingPathExtension().lastPathComponent;proofOptions.enabled=true
        } catch {errorMessage=error.localizedDescription}
    }
}
struct ProofControls:View {
    @ObservedObject var model:EditorModel
    var body:some View {
        InspectorSection(L("Soft Proofing"),symbol:"printer",visible:model.proofOptions.enabled,toggleVisibility:{model.proofOptions.enabled.toggle()}) {
            VStack(alignment:.leading,spacing:10) {
                HStack {Text(L(model.proofOptions.name)).lineLimit(1);Spacer();Button(L("选择 ICC…")) {model.chooseProofProfile()}}
                Picker(L("Rendering Intent"),selection:$model.proofOptions.intent) {Text(L("Relative Colorimetric")).tag(0);Text(L("Perceptual")).tag(1)}
                Toggle(L("Gamut Warning"),isOn:$model.proofOptions.gamutWarning)
                Text(L("仅影响预览，不修改照片或导出设置。")).foregroundStyle(Palette.muted)
            }.font(.system(size:10)).padding(.top,8)
        }.font(.system(size:11))
    }
}
