import LumaDomain
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
enum EntryPoint {
    @MainActor static func main() {
        if CommandLine.arguments.contains(where:{["--enhancement-check","--advanced-check","--self-test","--feature-check","--repair-check","--automatic-mask-check","--content-repair-check"].contains($0)}) {
            WorkflowStore.directoryOverride=FileManager.default.temporaryDirectory.appendingPathComponent("LumaLab-Isolated-Checks-"+UUID().uuidString)
        }
        if CommandLine.arguments.contains("--enhancement-check") {
            do {print(try EnhancementChecks.run());exit(0)} catch {fputs("ENHANCEMENT CHECK FAILED: \(error)\n",stderr);exit(1)}
        }
        if CommandLine.arguments.contains("--advanced-check") {
            do {print(try AdvancedChecks.run());exit(0)} catch {fputs("ADVANCED CHECK FAILED: \(error)\n",stderr);exit(1)}
        }
        if CommandLine.arguments.contains("--repair-check") {
            do {print(try RepairChecks.run());exit(0)} catch {fputs("REPAIR CHECK FAILED: \(error)\n",stderr);exit(1)}
        }
        if CommandLine.arguments.contains("--repair-benchmark") {
            do {print(try RepairChecks.benchmark());exit(0)} catch {fputs("BENCHMARK FAILED: \(error)\n",stderr);exit(1)}
        }
        if CommandLine.arguments.contains("--feature-check") {
            do {print(try FeatureChecks.run());exit(0)} catch {fputs("FEATURE CHECK FAILED: \(error)\n",stderr);exit(1)}
        }
        if CommandLine.arguments.contains("--content-repair-check") {
            do { print(try ContentRepairChecks.run()); exit(0) } catch { fputs("CONTENT REPAIR CHECK FAILED: \(error)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--automatic-mask-check") {
            do { print(try AutomaticMaskChecks.run()); exit(0) } catch { fputs("AUTOMATIC MASK CHECK FAILED: \(error)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--self-test") {
            do { print(try EngineChecks.run()); print(try IOChecks.run()); print(try WorkflowChecks.run()); print(try RevisionChecks.run()); print(try DNGChecks.run()); print(try RepairChecks.run()); print(try FileSettingsChecks.run()); print(try LocalizationChecks.run()); print(try AutomaticMaskChecks.run()); print(try ContentRepairChecks.run()); print(try FeatureChecks.run()); print(try AdvancedChecks.run()); print(try EnhancementChecks.run()); exit(0) }
            catch { fputs("SELF-TEST FAILED: \(error)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--localization-check") {
            do { print(try LocalizationChecks.run()); exit(0) } catch { fputs("LOCALIZATION CHECK FAILED: \(error)\n", stderr); exit(1) }
        }
        LumaLabApp.main()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: EditorModel?
    var mainWindowCloseApproved = false
    var recoveryObserver:NSObjectProtocol?
    var pendingURLs: [URL] = []
    func application(_ application: NSApplication, open urls: [URL]) {
        if let model = model { model.importFiles(urls) }
        else { pendingURLs.append(contentsOf:urls) }
    }
    func openPendingFiles() {
        guard let model = model, !pendingURLs.isEmpty else {return}
        let urls=pendingURLs;pendingURLs=[];model.importFiles(urls)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        recoveryObserver=NotificationCenter.default.addObserver(forName:NSWindow.didBecomeKeyNotification,object:nil,queue:.main) { [weak self] _ in
            DispatchQueue.main.async {self?.model?.offerRecovery()}
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if mainWindowCloseApproved { mainWindowCloseApproved = false; return .terminateNow }
        sender.keyWindow?.makeFirstResponder(nil)
        return model?.confirmUnsavedChanges() == false ? .terminateCancel : .terminateNow
    }
}

struct LumaLabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = EditorModel()
    @ObservedObject private var language = LanguageStore.shared
    var body: some Scene {
        Window("LumaLab", id: "main") {
            EditorView(model: model)
                .id(language.refreshID)
                .environment(\.locale, Locale(identifier: Localization.current.rawValue))
                .preferredColorScheme(.dark)
                .background(EditorWindowCloseGuard(model: model) { delegate.mainWindowCloseApproved = true })
                .onAppear { delegate.model = model; delegate.mainWindowCloseApproved = false; model.recoveryCompletion={delegate.openPendingFiles()}; DispatchQueue.main.async {model.offerRecovery();if !model.recoveryPromptActive {delegate.openPendingFiles()}} }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1380, height: 880)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(L("设置…")) { presentLanguageSettings() }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button(L("打开照片或项目…")) { model.openPanel() }.keyboardShortcut("o")
                Button(L("保存修改参数")) { NSApp.keyWindow?.makeFirstResponder(nil); model.saveCurrentEdits() }.keyboardShortcut("s")
                Button(L("保存为便携项目…")) { model.saveEmbeddedProject() }.keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button(L("导出 PNG…")) { model.exportImage(png: true) }.keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.isExporting)
                Button(L("导出 JPEG…")) { model.exportImage(png: false) }.disabled(model.isExporting)
                Button(L("导出颜色 LUT…")) { model.exportColorLUT() }.disabled(model.isExporting)
                Button(L("导出 TIFF…")) { model.exportOptions.format = .tiff; model.showExport = true }.disabled(model.isExporting)
            }
            CommandMenu(L("照片与版本")) {
                Button(L("照片库…")) { model.showLibrary = true }.keyboardShortcut("l")
                Button(L("多张照片堆栈…")) { model.showStack = true }
                Button(L("预设与编辑版本…")) { model.showVersions = true }
                Button(L("拍摄信息…")) { model.showMetadata = true }.keyboardShortcut("i", modifiers: [.command])
                Divider()
                Button(L("复制调整参数")) { model.copySettings() }.keyboardShortcut("c", modifiers: [.command, .shift])
                Button(L("粘贴调整参数")) { model.pasteSettings() }.keyboardShortcut("v", modifiers: [.command, .shift]).disabled(model.copiedSettings == nil)
                Divider()
                Toggle(L("显示选区高亮"), isOn: $model.showOverlay).keyboardShortcut("o", modifiers: [])
                Toggle(L("显示选区边框"), isOn: $model.showHandles)
                Toggle(L("显示高光与阴影剪切"), isOn: $model.showClipping).keyboardShortcut("j", modifiers: [])
            }
            CommandGroup(replacing: .undoRedo) {
                Button(L("撤销")) { model.undo() }.keyboardShortcut("z").disabled(!model.canUndo || model.editingLocked)
                Button(L("重做")) { model.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.canRedo || model.editingLocked)
            }
        }
        Settings { LanguageSettingsView() }
    }
}

@MainActor
private enum LanguageSettingsWindow {
    static var controller: NSWindowController?
    static func show() {
        if controller == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: LanguageSettingsView(onClose: { [weak window] in window?.close() }))
            window.center()
            controller = NSWindowController(window: window)
        }
        controller?.window?.title = L("设置")
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
@MainActor func presentLanguageSettings() { LanguageSettingsWindow.show() }

enum Palette {
    static let background = Color(red: 0.065, green: 0.072, blue: 0.082)
    static let panel = Color(red: 0.091, green: 0.100, blue: 0.111)
    static let raised = Color(red: 0.125, green: 0.138, blue: 0.150)
    static let muted = Color(red: 0.53, green: 0.57, blue: 0.60)
    static let accent = Color(red: 0.79, green: 0.88, blue: 0.57)
    static let border = Color.white.opacity(0.075)
}

struct EditorView: View {
    @ObservedObject var model: EditorModel
    @State private var showPresetCreation = false
    var body: some View {
        VStack(spacing: 0) {
            header.disabled(model.editingLocked)
            Divider().overlay(Palette.border)
            HStack(spacing: 0) {
                sidebar.frame(width: 194)
                Rectangle().fill(Palette.border).frame(width: 1)
                VStack(spacing: 0) {
                    canvasHeader
                    PhotoCanvas(model: model)
                    canvasFooter
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(Palette.border).frame(width: 1)
                InspectorView(model: model).frame(width: 302)
            }.disabled(model.editingLocked)
            statusBar
        }
        .background(Palette.background)
        .foregroundStyle(Color(white: 0.9))
        .tint(Palette.accent)
        .frame(minWidth: 1130, minHeight: 740)
        .alert(L("LumaLab"), isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button(L("好"), role: .cancel) { model.errorMessage = nil }
        } message: { Text(L(model.errorMessage ?? "")) }
        .sheet(isPresented: $showPresetCreation) {
            PresetCreationPanel(model: model) { showPresetCreation = false }
        }
        .modifier(WorkflowSheets(model: model))
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil, perform: acceptDrop)
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        let supported = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !supported.isEmpty else { return false }
        let group = DispatchGroup(), lock = NSLock()
        var results: [(Int, URL)] = []
        for (index, provider) in supported.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                var url: URL?
                if let value = item as? URL { url = value }
                else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let value = item as? String { url = URL(string: value) }
                if let url = url, url.isFileURL { lock.lock(); results.append((index, url)); lock.unlock() }
            }
        }
        group.notify(queue: .main) { model.importFiles(results.sorted { $0.0 < $1.0 }.map { $0.1 }) }
        return true
    }

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "circle.lefthalf.filled").font(.system(size: 22)).foregroundStyle(Palette.accent)
                Text(L("LUMA LAB")).font(.system(size: 13, weight: .bold, design: .rounded)).tracking(3)
            }.padding(.leading, 73)
            Text(L("/  光影实验室")).font(.system(size: 10, weight: .medium)).tracking(2).foregroundStyle(Palette.muted).padding(.leading, 14)
            Spacer()
            Text(model.sourceName).font(.system(size: 12, weight: .medium))
            if model.isModified { Circle().fill(Palette.accent).frame(width: 5, height: 5) }
            Spacer()
            iconButton("gearshape", help: L("设置")) { presentLanguageSettings() }
            iconButton("info.circle", help: "拍摄信息") { model.showMetadata = true }
            iconButton("arrow.uturn.backward", help: "撤销 · ⌘Z", action: model.undo).disabled(!model.canUndo || model.editingLocked)
            iconButton("arrow.uturn.forward", help: "重做 · ⇧⌘Z", action: model.redo).disabled(!model.canRedo || model.editingLocked)
            Rectangle().fill(Palette.border).frame(width: 1, height: 20).padding(.horizontal, 4)
            Button { NSApp.keyWindow?.makeFirstResponder(nil); model.saveCurrentEdits() } label: { Label(L("保存"), systemImage: "square.and.arrow.down") }.buttonStyle(.plain).font(.system(size: 11))
            Menu {
                Button(L("导出设置…")) { model.showExport = true }
                Button(L("导出 PNG…")) { model.exportImage(png: true) }
                Button(L("导出 JPEG…")) { model.exportImage(png: false) }
                Button(L("导出 16 位 TIFF…")) { model.exportOptions.format = .tiff; model.exportOptions.bitDepth = 16; model.showExport = true }
                Divider()
                Button(L("导出颜色 LUT…")) {model.exportColorLUT()}
            } label: {
                HStack(spacing: 8) { Text(L(model.isExporting ? "正在导出…" : "导出")); Image(systemName: "arrow.up.right") }
                    .font(.system(size: 11, weight: .semibold)).padding(.horizontal, 15).padding(.vertical, 8)
                    .background(Palette.accent, in: RoundedRectangle(cornerRadius: 6)).foregroundStyle(Palette.background)
            }.menuStyle(.borderlessButton).fixedSize().disabled(model.isExporting).padding(.leading, 10)
        }.padding(.trailing, 22).frame(height: 65)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("工作区").padding(.top, 18).padding(.bottom, 10)
            ForEach(EditorTool.allCases, id: \.self) { tool in
                Button { model.commit(); model.tool = tool } label: {
                    HStack(spacing: 11) {
                        Image(systemName: tool.symbol).frame(width: 18)
                        Text(L(tool == .masks ? "局部选区" : tool.title))
                        Spacer()
                        Text(L(tool == .edit ? "E" : tool == .crop ? "C" : tool == .repair ? "H" : "M")).font(.system(size: 9, design: .monospaced)).opacity(0.5)
                    }.font(.system(size: 12, weight: model.tool == tool ? .semibold : .regular))
                        .foregroundStyle(model.tool == tool ? Palette.accent : Color(white: 0.68))
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .contentShape(Rectangle())
                        .background(model.tool == tool ? Palette.accent.opacity(0.085) : .clear, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).keyboardShortcut(tool == .edit ? "e" : tool == .crop ? "c" : tool == .repair ? "h" : "m", modifiers: [])
            }
            Divider().padding(.vertical, 9)
            VStack(alignment: .leading, spacing: 11) {
                Button { model.showLibrary = true } label: { Label(L("照片库与批量处理"), systemImage: "square.grid.2x2") }
                Button { model.showStack = true } label: { Label(L("堆栈合成"), systemImage: "square.3.layers.3d") }
                Button { model.showVersions = true } label: { Label(L("预设与编辑版本"), systemImage: "clock.arrow.circlepath") }
            }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color(white: 0.72)).padding(.vertical, 4)
            Divider().padding(.vertical, 9)
            HStack {
                sectionLabel("预设")
                Spacer()
                Menu {
                    Button(L("保存当前为预设…")) { showPresetCreation = true }
                    Button(L("导入预设…")) { model.importUserPreset() }
                    Divider()
                    Button(L("管理预设…")) { model.showVersions = true }
                } label: { Image(systemName: "plus").frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .menuStyle(.borderlessButton).fixedSize().help(L("添加预设"))
            }.padding(.bottom, 6)
            PresetBrowser(model:model)
            Button { showPresetCreation = true } label: {
                Label(L("保存当前为预设…"),systemImage:"plus.circle").font(.system(size:10))
                    .frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,6).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(Palette.accent)
            Divider().padding(.vertical, 10)
            HStack(alignment: .center, spacing: 9) {
                if let image = model.beforePreview {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 58, height: 68)
                        .background(Palette.background, in: RoundedRectangle(cornerRadius: 5))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("当前照片")
                    Text(model.sourceName).font(.system(size: 10, weight: .medium)).lineLimit(2)
                    Text(L(model.dimensions + " px")).font(.system(size: 8, design: .monospaced)).foregroundStyle(Palette.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 68)
            Button { model.openPanel() } label: {
                Label(L("打开照片"), systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background(Palette.raised, in: RoundedRectangle(cornerRadius: 5))
            }.buttonStyle(.plain).font(.system(size: 11)).padding(.top, 10)
            Text(L("可直接拖入照片打开")).font(.system(size: 9)).foregroundStyle(Palette.muted.opacity(0.65)).padding(.top, 9).padding(.bottom, 12)
        }.padding(.horizontal, 17).background(Palette.panel)
    }

    private var canvasHeader: some View {
        HStack(spacing: 9) {
            Circle().fill(Palette.accent.opacity(0.8)).frame(width: 5, height: 5)
            Text(L(model.tool == .edit ? "整体调整" : model.tool == .crop ? "裁剪与几何" : model.tool == .repair ? "污点修复" : "局部选区"))
                .font(.system(size: 9, weight: .semibold)).tracking(1.8)
            Spacer()
            if model.tool == .masks {
                Text(L("选区基于裁剪与旋转前的画面")).font(.system(size: 10)).foregroundStyle(Palette.muted)
            } else { Text(L("标准颜色预览")).font(.system(size: 10)).foregroundStyle(Palette.muted) }
        }.padding(.horizontal, 25).frame(height: 54)
    }

    private var canvasFooter: some View {
        HStack(spacing: 15) {
            Button { model.showBefore.toggle() } label: {
                Label(L(model.showBefore ? "原图" : "对比"), systemImage: "rectangle.lefthalf.filled")
                    .foregroundStyle(model.showBefore ? Palette.accent : Color(white: 0.65))
            }.buttonStyle(.plain).keyboardShortcut("b", modifiers: []).help(L("原图／效果切换 · B"))
            if model.tool == .masks {
                Toggle(L("选区高亮"), isOn: $model.showOverlay).toggleStyle(.checkbox).help(L("整体显示或隐藏选区高亮，保留各选区设置 · O"))
            }
            Spacer()
            Menu {
                Button(L("单图")) {model.comparisonLayout = .single}
                Button(L("左右对比")) {model.comparisonLayout = .splitVertical}
                Button(L("上下对比")) {model.comparisonLayout = .splitHorizontal}
                Button(L("选择参考照片…")) {model.chooseReference()}
            } label:{Image(systemName:"rectangle.split.2x1")}.menuStyle(.borderlessButton).frame(width:28).accessibilityLabel(L("对比布局"))
            Button { model.tool = .edit; model.sampleMode = .whiteBalance } label: { Image(systemName: "eyedropper") }.buttonStyle(.plain).help(L("从照片采样白平衡"))
            Toggle(L("剪切警告"), isOn: $model.showClipping).toggleStyle(.checkbox).help(L("红色代表高光剪切，蓝色代表阴影剪切 · J"))
            Button { model.zoomBy(1 / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .buttonStyle(.plain).keyboardShortcut("-", modifiers: []).help(L("缩小 · −"))
            Button { model.zoomBy(1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .buttonStyle(.plain).keyboardShortcut("=", modifiers: []).help(L("放大 · +"))
            Picker(L("缩放"), selection: $model.zoom) {
                Text(L("适应窗口")).tag(1.0); Text(L("100% 像素")).tag(100.0); Text(L("200% 像素")).tag(200.0)
                if model.zoom != 1 && model.zoom != 100 && model.zoom != 200 {
                    Text(L(String(format: "%.0f%%", model.zoom))).tag(model.zoom)
                }
            }.labelsHidden().frame(width: 105)
        }.font(.system(size: 10)).padding(.horizontal, 25).frame(height: 50)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if model.isRendering || model.isExporting || model.isImporting || model.isStacking || model.isGeneratingMask { ProgressView().controlSize(.mini).scaleEffect(0.65).frame(width: 12) }
            else { Circle().fill(Palette.accent.opacity(0.7)).frame(width: 4, height: 4) }
            Text(L(model.isImporting ? "正在读取照片…" : model.isProcessingRepairs ? model.repairProcessingTitle : model.isRendering ? "正在更新预览…" : model.status)).lineLimit(1)
            Spacer()
            if model.isGeneratingMask { Button(L("取消识别")) { model.cancelAutomaticMask() }.buttonStyle(.plain).foregroundStyle(Palette.accent) }
            Text(L("位图 · 数字底片 · 相机原始文件")).tracking(1)
            Rectangle().fill(Palette.border).frame(width: 1, height: 10).padding(.horizontal, 9)
            Text(L("光影实验室 0.8")).foregroundStyle(Palette.muted)
        }.font(.system(size: 9)).foregroundStyle(Palette.muted).padding(.horizontal, 20).frame(height: 28)
            .background(Palette.panel).overlay(alignment: .top) { Rectangle().fill(Palette.border).frame(height: 1) }
    }

    private func lookColors(_ name: String) -> [Color] {
        switch name {
        case "柔和日光": return [Color(red: 0.91, green: 0.76, blue: 0.57), Color(red: 0.38, green: 0.56, blue: 0.48)]
        case "电影色调": return [Color(red: 0.19, green: 0.36, blue: 0.39), Color(red: 0.69, green: 0.48, blue: 0.32)]
        case "黑白": return [.gray, Color(white: 0.2)]
        default: return [Palette.accent, Color(red: 0.27, green: 0.43, blue: 0.46)]
        }
    }
}

func sectionLabel(_ text: String) -> some View { Text(L(text)).font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(Palette.muted) }

func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) { Image(systemName: symbol).font(.system(size: 12)).frame(width: 27, height: 28) }
        .buttonStyle(.plain).help(L(help))
}
