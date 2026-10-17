import LumaDomain
import SwiftUI

struct WorkflowSheets: ViewModifier {
    @ObservedObject var model: EditorModel
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $model.showLibrary) { LibraryPanel(model: model) }
            .sheet(isPresented: $model.showVersions) { VersionsPanel(model: model) }
            .sheet(isPresented: $model.showExport) { ExportPanel(model: model) }
            .sheet(isPresented: $model.showStack) { StackPanel(model: model) }
            .sheet(isPresented: $model.showMetadata) { MetadataPanel(model: model) }
    }
}

struct LibraryPanel: View {
    @ObservedObject var model: EditorModel
    @State private var search = ""
    @State private var minimumRating = 0
    @State private var collection = ""
    @State private var pickedOnly = false
    private var filtered: [PhotoLibraryItem] {
        model.workspace.library.filter { item in
            item.rating >= minimumRating && (!pickedOnly || item.flag == 1)
                && (collection.isEmpty || item.collection == collection)
                && (search.isEmpty || (item.name + " " + item.keywords).localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            sheetHeader("照片库", subtitle: "照片保留在原位置；这里只保存引用和筛选信息。") { model.showLibrary = false }
            HStack {
                TextField(L("搜索文件名或关键词"), text: $search).textFieldStyle(.roundedBorder)
                Picker(L("最低评分"), selection: $minimumRating) { ForEach(0...5, id: \.self) { Text(L($0 == 0 ? "全部评分" : "\($0) 星及以上")).tag($0) } }.frame(width: 160)
                Picker(L("相册"), selection: $collection) {
                    Text(L("全部相册")).tag("")
                    ForEach(Array(Set(model.workspace.library.map(\.collection))).filter { !$0.isEmpty }.sorted(), id: \.self) { Text(L($0)).tag($0) }
                }.frame(width: 150)
                Toggle(L("仅已选片"), isOn: $pickedOnly).toggleStyle(.checkbox)
            }
            HStack(spacing: 0) {
                List(selection: $model.librarySelection) {
                    ForEach(filtered) { item in
                        HStack(spacing: 10) {
                            Image(systemName: item.flag == 1 ? "flag.fill" : item.flag == -1 ? "xmark.circle" : "photo").foregroundStyle(item.flag == 1 ? Palette.accent : Palette.muted)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name).font(.system(size: 12, weight: .medium))
                                Text(L(item.url.deletingLastPathComponent().path)).font(.system(size: 9)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.head)
                            }
                            Spacer()
                            Text(L(String(repeating: "★", count: item.rating))).font(.system(size: 11)).foregroundStyle(Palette.accent)
                            Text(L(item.collection)).font(.system(size: 10)).foregroundStyle(Palette.muted)
                        }.padding(.vertical, 5).tag(item.id)
                            .contextMenu {
                                Button(L("打开")) { open(item.url) }
                                Button(L("标记为已选片")) { model.updateLibrary(item.path, flag: 1) }
                                Button(L("标记为淘汰")) { model.updateLibrary(item.path, flag: -1) }
                                Button(L("清除标记")) { model.updateLibrary(item.path, flag: 0) }
                                Menu(L("评分")) { ForEach(0...5, id: \.self) { value in Button(L("\(value) 星")) { model.updateLibrary(item.path, rating: value) } } }
                            }
                            .onTapGesture(count: 2) { open(item.url) }
                    }
                }.frame(minWidth: 450)
                Divider()
                selectedDetails.frame(width: 235).padding(.leading, 17)
            }.frame(minHeight: 285)
            HStack {
                Button(L("添加照片…")) { model.openPanel() }
                Button(L("打开选中照片")) { if let url = model.selectedURLs.first { open(url) } }.disabled(model.selectedURLs.isEmpty)
                Button(L("移除引用")) { model.removeFromLibrary(model.librarySelection) }.disabled(model.librarySelection.isEmpty)
                Spacer()
                Text(L("\(model.workspace.library.count) 张 · 已选 \(model.librarySelection.count) 张")).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Divider()
            HStack {
                Toggle(L("颜色与效果"), isOn: $model.batchColor).toggleStyle(.checkbox)
                Toggle(L("裁剪与几何"), isOn: $model.batchGeometry).toggleStyle(.checkbox)
                Toggle(L("局部选区"), isOn: $model.batchMasks).toggleStyle(.checkbox)
                if model.batchMasks {Toggle(L("按每张照片重新识别自动选区"),isOn:$model.adaptiveBatchMasks).toggleStyle(.checkbox)}
                Spacer()
                Button(L("复制当前参数")) { model.copySettings() }
                Button(L("粘贴到选中照片")) { model.applyCopiedToSelection() }.disabled(model.copiedSettings == nil || model.librarySelection.isEmpty || model.batchRunning)
                Button(L("批量导出…")) { model.batchExport() }.disabled(model.librarySelection.isEmpty || model.batchRunning)
            }.font(.system(size: 11))
            HStack {
                Toggle(L("保存时同步调整到选中的照片"), isOn: $model.autoSyncSelection).toggleStyle(.checkbox)
                Spacer()
                if model.batchRunning { ProgressView().controlSize(.small); Text(L("正在处理…")) }
                Text(L("导出格式与尺寸沿用“导出”面板中的设置。")).font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
        }.padding(24).frame(width: 990, height: 630).background(Palette.panel).preferredColorScheme(.dark)
    }
    private func open(_ url: URL) { model.showLibrary = false; DispatchQueue.main.async { model.open(url) } }
    @ViewBuilder private var selectedDetails: some View {
        if let path = model.librarySelection.first, let item = model.workspace.library.first(where: { $0.path == path }) {
            VStack(alignment: .leading, spacing: 16) {
                Text(item.name).font(.headline).lineLimit(2)
                Picker(L("评分"), selection: Binding(get: { item.rating }, set: { model.updateLibrary(path, rating: $0) })) { ForEach(0...5, id: \.self) { Text(L("\($0) 星")).tag($0) } }
                Picker(L("标记"), selection: Binding(get: { item.flag }, set: { model.updateLibrary(path, flag: $0) })) { Text(L("无标记")).tag(0); Text(L("已选片")).tag(1); Text(L("淘汰")).tag(-1) }
                TextField(L("关键词，以逗号分隔"), text: Binding(get: { item.keywords }, set: { model.updateLibrary(path, keywords: $0) })).textFieldStyle(.roundedBorder)
                TextField(L("所属相册"), text: Binding(get: { item.collection }, set: { model.updateLibrary(path, collection: $0) })).textFieldStyle(.roundedBorder)
                Text(L("使用 ⌘ 或 ⇧ 多选。移除引用不会删除照片或旁车文件。")).font(.system(size: 10)).foregroundStyle(Palette.muted)
                Spacer()
            }.padding(.top, 10)
        } else { Text(L("选择照片查看评分、标记、关键词与相册。")).foregroundStyle(Palette.muted).font(.system(size: 11)).frame(maxHeight: .infinity) }
    }
}

struct PresetCreationPanel: View {
    @ObservedObject var model: EditorModel
    var close: () -> Void
    @State private var name = ""
    @FocusState private var nameFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("保存自定义预设")).font(.title2.bold())
            Text(L("保存当前颜色与效果，之后可在左侧预设栏用于其他照片。"))
                .font(.callout).foregroundStyle(Palette.muted)
            TextField(L("预设名称"), text: $name).textFieldStyle(.roundedBorder).focused($nameFocused)
            HStack {
                Spacer()
                Button(L("取消"), action: close).keyboardShortcut(.cancelAction)
                Button(L("添加")) { model.saveUserPreset(name: name); close() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 420).background(Palette.panel).preferredColorScheme(.dark)
            .onAppear { nameFocused = true }
    }
}

struct VersionsPanel: View {
    @ObservedObject var model: EditorModel
    @State private var tab = 0
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sheetHeader("预设与编辑版本", subtitle: "预设可以跨照片复用；快照和虚拟副本保留本张照片的不同效果。") { model.showVersions = false }
            Picker(L("分类"), selection: $tab) { Text(L("我的预设")).tag(0); Text(L("快照")).tag(1); Text(L("虚拟副本")).tag(2); Text(L("历史记录")).tag(3) }.pickerStyle(.segmented)
            HStack {
                TextField(L(tab == 0 ? "预设名称" : "版本名称"), text: $name).textFieldStyle(.roundedBorder)
                Button(L(tab == 0 ? "保存当前预设" : tab == 1 ? "创建快照" : "创建虚拟副本")) {
                    if tab == 0 { model.saveUserPreset(name: name) }
                    else if tab == 1 { model.addSnapshot(name: name) }
                    else { model.createVirtualCopy(name: name) }
                    name = ""
                }.disabled(tab == 3)
                if tab == 0 { Button(L("导入预设…")) { model.importUserPreset() } }
            }
            List {
                if tab == 0 {
                    if model.workspace.presets.isEmpty { Text(L("还没有自定义预设。调整照片后，可将当前颜色和效果保存为预设。")).foregroundStyle(Palette.muted) }
                    ForEach(model.workspace.presets) { preset in
                        HStack { Text(preset.name); Spacer(); Button(L("应用颜色")) { model.applyUserPreset(preset) }; Menu(L("更多")) { Button(L("应用全部参数")) { model.applyUserPreset(preset, includeGeometry: true, includeMasks: true) }; Button(L("导出预设…")) { model.exportUserPreset(preset) }; Button(L("删除预设")) { model.deleteUserPreset(preset.id) } } }
                    }
                } else if tab == 1 {
                    ForEach(model.snapshots) { snapshot in HStack { Text(snapshot.name); Spacer(); Button(L("恢复")) { model.restoreSnapshot(snapshot) }; Button(L("删除")) { model.deleteSnapshot(snapshot.id) } } }
                    if model.snapshots.isEmpty { Text(L("创建命名快照，随时回到某个编辑阶段。")).foregroundStyle(Palette.muted) }
                } else if tab == 2 {
                    ForEach(model.virtualCopies) { copy in
                        HStack { Text(copy.name); Spacer(); Button(L("载入")) { model.restoreSnapshot(copy) }; Button(L("保存当前到此副本")) { model.updateVirtualCopy(copy.id) }; Button(L("删除")) { model.deleteVirtualCopy(copy.id) } }
                    }
                    Text(L("虚拟副本只记录独立参数，不复制原始照片。载入后编辑，点击“保存当前到此副本”更新。")).font(.system(size: 10)).foregroundStyle(Palette.muted)
                } else {
                    ForEach(Array(model.history.indices.reversed()), id: \.self) { index in
                        HStack { Text(L(index == 0 ? "打开时的状态" : "编辑步骤 \(index)")); Spacer(); Text(L("曝光 \(String(format: "%.2f", model.history[index].adjustments.exposure)) · \(model.history[index].masks.count) 个选区")).font(.system(size: 10)).foregroundStyle(Palette.muted); if index == model.historyIndex { Image(systemName: "checkmark").foregroundStyle(Palette.accent) }; Button(L("恢复")) { model.restoreHistoryIndex(index) } }
                    }
                }
            }
            Text(L("保存会记录参数、快照、副本和最近 80 步历史；便携项目也可保留这些内容。")).font(.system(size: 10)).foregroundStyle(Palette.muted)
        }.padding(24).frame(width: 830, height: 530).background(Palette.panel).preferredColorScheme(.dark)
    }
}

struct ExportPanel: View {
    @ObservedObject var model: EditorModel
    @State private var presetName = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sheetHeader("导出照片", subtitle: "导出会应用当前调整；原始文件和旁车参数不会被覆盖。") { if !model.isExporting { model.showExport = false } }
            Form {
                Picker(L("文件格式"), selection: $model.exportOptions.format) { ForEach(OutputFormat.allCases) { Text(L($0.title)).tag($0) } }
                if model.exportOptions.format == .jpeg {
                    AdjustmentSlider(title:"图像质量",value:$model.exportOptions.quality,range:0.1...1,unit:"%",multiplier:100,inputFactor:1,commit:{})
                }
                if model.exportOptions.format == .tiff {
                    Picker(L("位深"), selection: $model.exportOptions.bitDepth) { Text(L("8 位")).tag(8); Text(L("16 位")).tag(16) }
                }
                Picker(L("输出颜色空间"), selection: $model.exportOptions.colorSpace) { ForEach(OutputColorSpace.allCases) { Text(L($0.title)).tag($0) } }
                TextField(L("最长边像素（0 为原始尺寸）"), value: $model.exportOptions.longEdge, formatter: NumberFormatter()).textFieldStyle(.roundedBorder)
                Toggle(L("不放大小尺寸照片"), isOn: $model.exportOptions.dontEnlarge)
                AdjustmentSlider(title:"输出锐化",value:$model.exportOptions.outputSharpening,range:0...100,commit:{})
                TextField(L("文字水印（留空则不添加）"), text: $model.exportOptions.watermark).textFieldStyle(.roundedBorder)
                Toggle(L("保留拍摄信息与关键词"), isOn: $model.exportOptions.includeMetadata)
            }.font(.system(size: 12))
            Divider()
            HStack {
                Menu(L("载入导出预设")) { ForEach(model.workspace.exportPresets) { preset in Button(preset.name) { model.exportOptions = preset.options } } }
                TextField(L("新预设名称"), text: $presetName).textFieldStyle(.roundedBorder)
                Button(L("保存预设")) { model.saveExportPreset(name: presetName); presetName = "" }.disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack { Text(L("当前处理使用独立算法；16 位输出可保留更多处理精度，但不会恢复已丢失的原始细节。")).font(.system(size: 10)).foregroundStyle(Palette.muted); Spacer(); Button(L(model.isExporting ? "正在导出…" : "选择位置并导出…")) { model.exportCurrent() }.buttonStyle(.borderedProminent).disabled(model.isExporting) }
        }.padding(26).frame(width: 650, height: 520).background(Palette.panel).preferredColorScheme(.dark)
    }
}

struct StackPanel: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sheetHeader("多张照片堆栈", subtitle: "支持降噪、星轨、HDR、Focus Stacking 与 Panorama。合成结果作为新的 16 位图像继续编辑。") { if !model.isStacking { model.showStack = false } }
            Picker(L("合成方式"), selection: $model.stackMode) { ForEach(StackMode.allCases) { Text(L($0.title)).tag($0) } }
                .onChange(of: model.stackMode) { if $0 == .starTrails { model.alignStack = false } }
            Toggle(L("自动对齐并裁去边缘空白"), isOn: $model.alignStack).disabled(model.stackMode == .starTrails || model.stackMode == .panorama)
            if model.alignStack && model.stackMode != .panorama && model.stackMode != .starTrails {Toggle(L("Rotation Registration"),isOn:$model.rotationStack)}
            if model.stackMode == .hdr {AdjustmentSlider(title:"Deghost",value:$model.stackDeghost,range:0...1,unit:"%",multiplier:100,inputFactor:1,commit:{})}
            if model.stackMode == .sigmaClip {AdjustmentSlider(title:"Sigma Threshold",value:$model.stackSigma,range:1...5,precision:1,defaultValue:3,inputFactor:1,commit:{})}
            Text(L(model.stackMode == .starTrails ? "星轨保留星体运动，使用变亮叠加；建议三脚架拍摄，不进行星体对齐。" : model.stackMode == .hdr ? "HDR 融合可使用 Deghost；结果为 SDR 图像。" : "支持 Rotation Registration、Sigma-clipped 降噪、Focus Stacking 与 Projective Panorama；场景视差仍可能影响合成。"))
                .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
            List {
                ForEach(Array(model.stackURLs.enumerated()), id: \.offset) { index, url in HStack { Text(L("\(index + 1)")).foregroundStyle(Palette.muted); Text(L(url.lastPathComponent)); Spacer() } }
            }
            HStack { Button(L("选择多张照片…")) { model.chooseStackFiles() }.disabled(model.isStacking); Button(L("使用照片库选中的照片")) { model.stackURLs = model.selectedURLs }.disabled(model.isStacking || model.selectedURLs.count < 2); Spacer(); Text(L("\(model.stackURLs.count) 张")).foregroundStyle(Palette.muted) }
            Text(L(model.stackMode == .panorama ? "Panorama 支持 2–8 张按顺序拍摄且有重叠的照片；输出最多 1 亿像素。允许不同尺寸，保留边缘透明区域。" : "单张最多 1 亿像素；中位数最多 15 张，其他方式最多 32 张。不会偷偷降低分辨率；照片尺寸需要一致。")).font(.system(size: 10)).foregroundStyle(Palette.muted)
            if model.isStacking { ProgressView(value: model.stackProgress); Text(L("处理中 \(Int(model.stackProgress * 100))%")).font(.system(size: 11)) }
            HStack { Spacer(); Button(L(model.isStacking ? "正在合成…" : "开始合成")) { model.runStack() }.buttonStyle(.borderedProminent).disabled(model.stackURLs.count < 2 || model.isStacking) }
        }.padding(26).frame(width: 760, height: 710).background(Palette.panel).preferredColorScheme(.dark)
    }
}

struct MetadataPanel: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            sheetHeader("拍摄与文件信息", subtitle: model.sourceName) { model.showMetadata = false }
            if let metadata = model.imageMetadata {
                ScrollView {
                    VStack(alignment: .leading, spacing: 11) {
                        ForEach(Array(metadata.rows.enumerated()), id: \.offset) { _, row in HStack(alignment: .top) { Text(L(row.0)).foregroundStyle(Palette.muted).frame(width: 125, alignment: .leading); Text(L(row.1)).textSelection(.enabled); Spacer() } }
                    }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let url = model.sourceURL {
                Text(L("修改描述文件：\(WorkflowStore.sidecarURL(for: url).lastPathComponent)")).font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
        }.padding(24).frame(width: 650, height: 500).background(Palette.panel).preferredColorScheme(.dark)
    }
}

func sheetHeader(_ title: String, subtitle: String, close: @escaping () -> Void) -> some View {
    HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 6) { Text(L(title)).font(.system(size: 20, weight: .semibold)); Text(L(subtitle)).font(.system(size: 11)).foregroundStyle(Palette.muted) }
        Spacer()
        Button(action: close) { Image(systemName: "xmark.circle.fill").font(.system(size: 19)).foregroundStyle(Palette.muted) }.buttonStyle(.plain)
    }
}
