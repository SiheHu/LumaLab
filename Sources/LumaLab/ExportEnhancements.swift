import LumaDomain
import AppKit
import CoreImage
import UniformTypeIdentifiers

@MainActor extension EditorModel {
    func cancelExportEstimate() {
        estimateGeneration += 1; estimateWork?.cancel(); estimatePending=false; exportEstimate=nil; estimateFailed=false
    }
    func requestExportEstimate() {
        cancelExportEstimate()
        guard showExport, let source else { return }
        let ticket=estimateGeneration, document=documentID, state=edits, options=exportOptions
        let metadata=imageMetadata?.properties ?? [:]
        estimatePending=true
        let work=DispatchWorkItem { [weak self, renderer] in
            let result=Result { try renderer.estimateExport(source:source,edits:state,options:options,metadata:metadata) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.estimateGeneration==ticket, self.documentID==document, self.showExport else {return}
                self.estimatePending=false
                switch result {case .success(let bytes):self.exportEstimate=bytes
                case .failure:self.estimateFailed=true}
            }
        }
        estimateWork=work; auxiliaryQueue.asyncAfter(deadline:.now()+0.4,execute:work)
    }
    func exportColorLUT() {
        guard !isExporting, !editingLocked else {return}
        let panel=NSSavePanel(); panel.title=L("导出颜色 LUT")
        panel.allowedContentTypes=[UTType(filenameExtension:"cube") ?? .plainText]
        panel.nameFieldStringValue="LumaLab-look.cube"
        panel.message=L("导出 sRGB 全局颜色变换。不包含局部选区、修复、裁剪、颗粒、暗角、清晰度与降噪。")
        guard panel.runModal() == .OK, let url=panel.url else {return}
        guard ![sourceURL,projectURL].compactMap({$0}).contains(where:{$0.standardizedFileURL.resolvingSymlinksInPath()==url.standardizedFileURL.resolvingSymlinksInPath()}) else {errorMessage="不能覆盖原始照片或当前项目";return}
        let state=edits
        isExporting=true
        auxiliaryQueue.async { [weak self] in
            do {
                let cube=try ImagePipeline().globalColorLUT(edits:state)
                try cube.serialized().write(to:url,atomically:true,encoding:.utf8)
                DispatchQueue.main.async { [weak self] in self?.isExporting=false;self?.status="颜色 LUT 已导出"}
            } catch { DispatchQueue.main.async { [weak self] in self?.isExporting=false;self?.errorMessage=error.localizedDescription} }
        }
    }
    func requestScopes() {
        scopeGeneration += 1
        guard scopesExpanded, let image=(showBefore ? beforePreview:preview) else {return}
        let ticket=scopeGeneration, document=documentID
        scopeQueue.async { [weak self, renderer] in
            let result=renderer.scopeAnalysis(image)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.scopesExpanded, self.scopeGeneration==ticket, self.documentID==document else {return}
                self.scopes=result
            }
        }
    }
    func duplicateComponent(id: UUID?, inverted: Bool = false) {
        guard !editingLocked, let i=selectedMaskIndex else {return}
        guard var item = id == nil ? edits.masks[i].shape : edits.masks[i].components.first(where:{$0.id==id}) else {return}
        item.id=UUID()
        if inverted {item.inverted.toggle()}
        edits.masks[i].components.append(item); activeComponentID=item.id; pendingShapePlacement=false
        commit();requestRender()
    }
    func invertComponent(id: UUID) {
        guard !editingLocked, let i=selectedMaskIndex, let k=edits.masks[i].components.firstIndex(where:{$0.id==id}) else {return}
        edits.masks[i].components[k].inverted.toggle();commit();requestRender()
    }
}
