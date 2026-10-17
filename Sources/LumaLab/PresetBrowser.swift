import LumaDomain
import SwiftUI
import CoreImage
import AppKit

@MainActor extension EditorModel {
    func requestPresetPreviews() {
        presetPreviewWork?.cancel();presetPreviewGeneration += 1
        guard let source else {return}
        let ticket=presetPreviewGeneration,document=documentID,base=edits
        var entries=BuiltInPreset.allCases.map { preset -> (String,EditState) in
            var state=base;state.adjustments=preset.state.adjustments
            return (preset.rawValue,state)
        }
        entries += workspace.presets.map {($0.id.uuidString,mergedSettings($0.state,into:base,color:true,geometry:false,masks:false))}
        // Only image thumbnails live in memory, never inside exported presets.
        let work=DispatchWorkItem { [weak self] in
            let renderer=ImagePipeline()
            let scale=min(1,180/max(source.extent.width,source.extent.height))
            let proxy=source.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
            for (key,var state) in entries {
                state.masks=[];state.repairs=[];state.crop = .full;state.geometry = .init();state.quarterTurns=0;state.flipHorizontal=false
                guard let cg=try? renderer.render(source:proxy,edits:state,maxDimension:180) else {continue}
                DispatchQueue.main.async { [weak self] in
                    guard let self,self.documentID==document,self.presetPreviewGeneration==ticket else {return}
                    self.presetPreviews[key]=cg
                }
            }
        }
        presetPreviewWork=work;auxiliaryQueue.asyncAfter(deadline:.now()+0.15,execute:work)
    }
    func updatePresetDetails(_ id:UUID, category:String, author:String) {
        guard let index=workspace.presets.firstIndex(where:{$0.id==id}) else {return}
        workspace.presets[index].category=category.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? "自定义":String(category.prefix(80))
        workspace.presets[index].author=String(author.prefix(120))
        persistWorkspace()
    }
}

private struct PresetCategory:Identifiable { let id:String; let title:String }

struct PresetBrowser:View {
    @ObservedObject var model:EditorModel
    @State private var category="@all"
    @State private var search=""
    private var categories:[PresetCategory] {
        [PresetCategory(id:"@all",title:L("全部")),PresetCategory(id:"@builtin",title:L("内置"))] + Array(Set(model.workspace.presets.map(\.category))).sorted().map {PresetCategory(id:"user:"+$0,title:$0)}
    }
    private func matches(_ name:String,_ author:String="",localized:Bool=false)->Bool {
        search.isEmpty || (localized ? L(name):name).localizedCaseInsensitiveContains(search) || author.localizedCaseInsensitiveContains(search)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            TextField(L("搜索预设…"),text:$search).textFieldStyle(.roundedBorder).font(.system(size:10))
            Picker(L("预设分类"),selection:$category) {ForEach(categories) {Text(verbatim:$0.title).tag($0.id)}}.labelsHidden().controlSize(.small)
            ScrollView(.vertical) {
                LazyVStack(alignment:.leading,spacing:6) {
                    if category == "@all" || category == "@builtin" {
                        ForEach(BuiltInPreset.allCases.filter {matches($0.rawValue,localized:true)},id:\.rawValue) {preset in
                            Button {model.applyPreset(preset.rawValue)} label: {
                                row(name:preset.rawValue,author:"LumaLab",category:preset.category,key:preset.rawValue,localized:true)
                            }.buttonStyle(.plain)
                        }
                    }
                    ForEach(model.workspace.presets.filter {(category == "@all" || category == "user:"+$0.category) && matches($0.name,$0.author)}) {preset in
                        Button {model.applyUserPreset(preset)} label: {
                            row(name:preset.name,author:preset.author,category:preset.category,key:preset.id.uuidString,localized:false)
                        }.buttonStyle(.plain).contextMenu {
                            Button(L("应用颜色")) {model.applyUserPreset(preset)}
                            Button(L("编辑分类与作者…")) {model.presentPresetDetails(preset)}
                            Button(L("导出预设…")) {model.exportUserPreset(preset)}
                            Button(L("删除预设")) {model.deleteUserPreset(preset.id)}
                        }
                    }
                }
            }.scrollIndicators(.visible)
        }.frame(minHeight:100)
            .task(id:model.documentID) {model.requestPresetPreviews()}
             .onChange(of:model.historyIndex) {_ in model.requestPresetPreviews()}
            .onChange(of:model.workspace.presets.map(\.id)) {_ in model.requestPresetPreviews();if !categories.contains(where:{$0.id==category}) {category="@all"}}
            .help(L("预览当前照片的整体颜色与效果，不包含局部选区和修复。"))
    }
    private func row(name:String,author:String,category:String,key:String,localized:Bool)->some View {
        HStack(spacing:8) {
            Group {
                if let image=model.presetPreviews[key] {Image(decorative:image,scale:1).resizable().aspectRatio(contentMode:.fill)}
                else {Rectangle().fill(Palette.raised).overlay(Image(systemName:"photo").foregroundStyle(Palette.muted))}
            }.frame(width:54,height:40).clipped().cornerRadius(3)
            VStack(alignment:.leading,spacing:3) {
                Text(verbatim:localized ? L(name):name).font(.system(size:10,weight:.medium)).lineLimit(1)
                Text(verbatim:author.isEmpty ? (localized ? L(category):category):"\(localized ? L(category):category) · \(author)").font(.system(size:8)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Spacer(minLength:0)
        }.padding(.vertical,2).contentShape(Rectangle())
    }
}

@MainActor extension EditorModel {
    func presentPresetDetails(_ preset:UserPreset) {
        let alert=NSAlert();alert.messageText=L("编辑分类与作者")
        alert.informativeText=L("分类用于预设筛选；作者信息会随预设导出。")
        let view=NSStackView();view.orientation = .vertical;view.alignment = .leading;view.spacing=8
        let category=NSTextField(string:preset.category),author=NSTextField(string:preset.author)
        category.placeholderString=L("分类");author.placeholderString=L("作者（可选）")
        view.addArrangedSubview(NSTextField(labelWithString:L("分类")));view.addArrangedSubview(category)
        view.addArrangedSubview(NSTextField(labelWithString:L("作者（可选）")));view.addArrangedSubview(author)
        view.frame=NSRect(x:0,y:0,width:300,height:100)
        category.widthAnchor.constraint(equalToConstant:300).isActive=true;author.widthAnchor.constraint(equalToConstant:300).isActive=true
        alert.accessoryView=view;alert.addButton(withTitle:L("保存"));alert.addButton(withTitle:L("取消"))
        if alert.runModal() == .alertFirstButtonReturn {updatePresetDetails(preset.id,category:category.stringValue,author:author.stringValue)}
    }
}
