import LumaDomain
import UniformTypeIdentifiers
import AppKit
import SwiftUI
import CoreImage

@MainActor extension EditorModel {
    func importLUT() {
        let panel=NSOpenPanel();panel.allowedContentTypes=[UTType(filenameExtension:"cube") ?? .plainText]
        guard panel.runModal() == .OK,let url=panel.url else {return}
        do {
            let data=try Data(contentsOf:url);guard data.count<=16*1024*1024,let text=String(data:data,encoding:.utf8) else {throw CubeLUT.Failure.invalid("Invalid UTF-8 LUT")}
            edits.lut.cube=try CubeLUT(text:text,name:url.deletingPathExtension().lastPathComponent);edits.lut.amount=1;edits.lut.enabled=true
            commit();requestRender()
        } catch {errorMessage="LUT 读取失败：\(error.localizedDescription)"}
    }
    func beginPresetAmount(base: EditState, target: EditState) {presetBase=base;presetTarget=target;presetAmount=1}
    func updatePresetAmount(_ amount:Double) {
        guard let base=presetBase,let target=presetTarget else {return}
        presetAmount=amount;edits=PresetInterpolation.apply(base:base,target:target,amount:amount);requestRender()
    }
    func groupSelectedMasks() {
        guard maskSelection.count>=2 else {return}
        let id=UUID(),name="组选区 \(Set(edits.masks.compactMap(\.groupID)).count+1)"
        for i in edits.masks.indices where maskSelection.contains(edits.masks[i].id) {edits.masks[i].groupID=id;edits.masks[i].groupName=name}
        commit();requestRender()
    }
    func renameMaskGroup(_ id:UUID,name:String) {
        for i in edits.masks.indices where edits.masks[i].groupID==id {edits.masks[i].groupName=name}
        commit()
    }
    func toggleMaskGroup(_ id:UUID) {
        let enable = !edits.masks.filter {$0.groupID==id}.allSatisfy(\.enabled)
        for i in edits.masks.indices where edits.masks[i].groupID==id {edits.masks[i].enabled=enable}
        commit();requestRender()
    }
    func ungroupMasks(_ id:UUID) {
        for i in edits.masks.indices where edits.masks[i].groupID==id {edits.masks[i].groupID=nil;edits.masks[i].groupName=nil}
        commit()
    }
    func mergeSelectedMasks() {
        guard let source,let selected=selectedMask,maskSelection.count>=2,maskSelection.contains(selected.id) else {return}
        do {
            let masks=edits.masks.filter {maskSelection.contains($0.id)}
            var pixels=[UInt8](),w=0,h=0
            for mask in masks {
                let cg=try overlayRenderer.coveragePreview(mask,source:source)
                let raw=[UInt8](cg.dataProvider!.data! as Data);w=cg.width;h=cg.height
                if pixels.isEmpty {pixels=[UInt8](repeating:0,count:w*h)}
                for y in 0..<h {for x in 0..<w {pixels[y*w+x]=max(pixels[y*w+x],raw[y*cg.bytesPerRow+x*4])}}
            }
            var merged=LocalMask(name:"合并选区",kind:.automatic)
            merged.adjustments=selected.adjustments;merged.hsl=selected.hsl;merged.disabledSections=selected.disabledSections
            merged.raster=try PortableMaskRaster(width:w,height:h,pixels:Data(pixels),modelID:"merged-coverage-v1")
            edits.masks.removeAll {maskSelection.contains($0.id)};edits.masks.append(merged);selectedMaskID=merged.id;maskSelection=[]
            commit();requestRender()
        } catch {errorMessage=error.localizedDescription}
    }
    func chooseReference() {
        let panel=NSOpenPanel();panel.allowedContentTypes=PhotoIO.supportedContentTypes
        guard panel.runModal() == .OK,let url=panel.url else {return}
        let ticket=documentID
        ioQueue.async { [weak self] in
            do {
                let data=try Data(contentsOf:url),decoded=try PhotoIO.decode(data:data,fileExtension:url.pathExtension)
                let state=try PhotoSettingsStore.read(for:url,data:data)?.edits ?? .init()
                let renderer=ImagePipeline();let image=try renderer.render(source:decoded.image,edits:state,maxDimension:2400)
                let pixelSize=try renderer.outputSize(source:decoded.image,edits:state)
                DispatchQueue.main.async {
                    guard let self,self.documentID==ticket else {return}
                    self.referencePreview=image;self.referencePixelSize=pixelSize;self.referenceName=url.lastPathComponent;self.comparisonLayout = .reference
                }
            } catch {DispatchQueue.main.async {self?.errorMessage=error.localizedDescription}}
        }
    }
}

struct CreativeInspector:View {
    @ObservedObject var model:EditorModel
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            ProofControls(model:model)
            if model.presetTarget != nil {
                AdjustmentSlider(title:"预设强度",value:Binding(get:{model.presetAmount},set:{model.updatePresetAmount($0)}),range:0...2,unit:"%",multiplier:100,defaultValue:1,inputFactor:1,commit:{model.commit()})
            }
            HStack {Text(L("LUT 风格")).font(.system(size:12,weight:.semibold));Spacer();Button {model.edits.lut.enabled.toggle();model.commit();model.requestRender()} label:{Image(systemName:model.edits.lut.enabled ? "eye":"eye.slash")}.buttonStyle(.plain)}
            Text(L(model.edits.lut.cube?.name ?? L("尚未载入 LUT"))).font(.system(size:10)).foregroundStyle(Palette.muted)
            HStack {Button(L("导入 .cube…")) {model.importLUT()};Spacer();Button(L("移除")) {model.edits.lut = .init();model.commit();model.requestRender()}.disabled(model.edits.lut.cube==nil)}.font(.system(size:10))
            if model.edits.lut.cube != nil {
                AdjustmentSlider(title:"LUT 强度",value:Binding(get:{model.edits.lut.amount},set:{model.edits.lut.amount=$0;model.requestRender()}),range:0...2,unit:"%",multiplier:100,defaultValue:1,inputFactor:1,commit:{model.commit()})
            }
        }.padding(10).background(Palette.raised,in:RoundedRectangle(cornerRadius:6))
    }
}
