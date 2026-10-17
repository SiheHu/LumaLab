import LumaDomain
import AppKit
import SwiftUI
import CoreImage
import UniformTypeIdentifiers

@MainActor
final class EditorModel: ObservableObject {
    @Published var edits = EditState()
    @Published var tool: EditorTool = .edit { didSet { sampleMode = .none; isDrawingMask = false; requestRender() } }
    @Published var preview: CGImage?
    @Published var beforePreview: CGImage?
    @Published var previewPixelSize = CGSize.zero
    @Published var maskOverlay: CGImage?
    @Published var histogram: [[Double]] = []
    @Published var documentID=UUID()
    @Published var sourceName = "山间晨光"
    @Published var sourceSize = CGSize.zero
    @Published var isDemo = true
    @Published var isGeneratingMask = false
    @Published var automaticMaskTask: AutomaticMaskKind?
    var automaticMaskGeneration = 0
    let inferenceQueue = DispatchQueue(label: "com.local.lumalab.inference", qos: .userInitiated)
    @Published var isRendering = false
    @Published var isExporting = false
    @Published var isImporting = false
    @Published var proofOptions=ProofOptions() {didSet {if oldValue != proofOptions {requestRender()}}}
    @Published var comparisonLayout: ComparisonLayout = .single
    @Published var viewportCenter = UnitPoint2D.center
    @Published var referencePreview: CGImage?
    @Published var referencePixelSize = CGSize.zero
    @Published var referenceName = ""
    @Published var presetAmount:Double = 1
    var presetBase:EditState?
    @Published var presetTarget:EditState?
    @Published var maskSelection=Set<UUID>()
    var recoveryEnabled=true
    var recoveryOffered=false
    var recoveryPromptActive=false
    weak var editorWindow:NSWindow?
    var recoveryCompletion:(()->Void)?
    var recoveryWork:DispatchWorkItem?
    @Published var showBefore = false
    /// View-level master switch; never overwrites the saved settings of individual masks.
    @Published var showOverlay = true {
        didSet { if oldValue != showOverlay { requestMaskOverlay() } }
    }
    @Published var isDrawingMask = false {
        didSet { if oldValue != isDrawingMask { requestMaskOverlay() } }
    }
    /// All opted-in masks remain visible; drawing temporarily opts in the active one.
    var overlayMasks: [(mask: LocalMask, alpha: Double)] {
        edits.masks.compactMap { mask in
            let selected = mask.id == selectedMaskID
            guard (showOverlay && mask.overlayVisible) || (selected && isDrawingMask) else { return nil }
            return (mask, selected ? 0.48 : 0.16)
        }
    }
    @Published var showHandles = true
    var selectedMaskHandlesVisible: Bool { showHandles && (selectedMask?.handlesVisible ?? true) }
    func setMaskOverlayVisible(_ id: UUID, _ visible: Bool) {
        guard let i=edits.masks.firstIndex(where: {$0.id==id}), edits.masks[i].overlayVisible != visible else {return}
        edits.masks[i].overlayVisible=visible;commit();requestMaskOverlay()
    }
    func setMaskHandlesVisible(_ id: UUID, _ visible: Bool) {
        guard let i=edits.masks.firstIndex(where: {$0.id==id}), edits.masks[i].handlesVisible != visible else {return}
        edits.masks[i].handlesVisible=visible;commit()
    }
    @Published var showGeometryGuides = true
    @Published var showClipping = false
    @Published var selectedRepairID:UUID?
    @Published var repairMode:RepairMode = .heal
    @Published var repairRadius:Double = 0.015
    @Published var repairFeather:Double = 0.5
    @Published var repairOpacity:Double = 1
    @Published var repairDraft:[UnitPoint2D] = []
    @Published var showRepairHandles=true
    @Published var repairAutoSample=true
    @Published var isPickingRepairSource=false
    @Published var repairManualSource:UnitPoint2D?
    @Published var isFindingRepairSource=false
    var repairSearchGeneration=0
    var repairVariant=0
    @Published var selectedMaskID: UUID? {
        didSet {if selectedMaskID != oldValue {pendingShapePlacement=false; isDrawingMask=false; requestMaskOverlay()}}
    }
    @Published var pendingShapePlacement = false
    @Published var activeComponentID: UUID?
    @Published var autoMaskBrush = false
    @Published var autoMaskTolerance: Double = 0.15
    @Published var coveragePreviewEnabled = false {didSet {requestMaskOverlay()}}
    @Published var coverageImage: CGImage?
    @Published var brushErase = false
    @Published var sampleMode: SampleMode = .none { didSet { if sampleMode != .none { status = sampleMode.instruction } } }
    @Published var errorMessage: String?
    @Published var status = "就绪"
    @Published var fitZoom: Double = 100
    @Published var zoom: Double = 1 {
        didSet {
            let wasFull = oldValue != 1 && oldValue > fitZoom * 1.05
            if wasFull != fullResolutionPreview { requestRender() }
        }
    }
    @Published var cropAspect: Double?
    @Published var history: [EditState] = [.init()]
    @Published var historyIndex = 0
    @Published var savedState: EditState?
    @Published var documentStructureDirty = false
    @Published var newDocumentNeedsSave = false
    @Published var snapshots: [SavedSnapshot] = []
    @Published var virtualCopies: [SavedSnapshot] = []
    @Published var workspace = WorkspaceData()
    @Published var librarySelection = Set<String>()
    @Published var imageMetadata: PhotoMetadata?
    @Published var exportOptions = ExportOptions()
    @Published var copiedSettings: EditState?
    @Published var showLibrary = false
    @Published var showVersions = false
    @Published var showExport = false
    @Published var showStack = false
    @Published var showMetadata = false
    @Published var stackURLs: [URL] = []
    @Published var stackMode: StackMode = .average
    @Published var alignStack = false
    @Published var rotationStack = true
    @Published var stackDeghost:Double = 0.5
    @Published var stackSigma:Double = 3
    @Published var stackProgress = 0.0
    @Published var isStacking = false
    @Published var batchColor = true
    @Published var batchGeometry = false
    @Published var adaptiveBatchMasks = true
    @Published var batchMasks = false
    @Published var batchRunning = false
    @Published var autoSyncSelection = false
    var sourceData = Data()
    var source: CIImage?
    var sourceURL: URL?
    var projectURL: URL?
    var sourceDigest = ""
    let renderer = ImagePipeline()
    let renderQueue = DispatchQueue(label: "com.local.lumalab.render", qos: .userInitiated)
    let ioQueue = DispatchQueue(label: "com.local.lumalab.io", qos: .userInitiated)
    let overlayRenderer = ImagePipeline()
    let overlayQueue = DispatchQueue(label: "com.local.lumalab.overlay", qos: .userInteractive)
    var overlayWork: DispatchWorkItem?
    var overlayGeneration = 0
    var renderWork: DispatchWorkItem?
    var autosaveWork: DispatchWorkItem?
    var generation = 0
    var importGeneration = 0
    var beforeKey: EditState?
    var beforeLimit: CGFloat?
    var beforeApplyCrop = true
    var checkpoint = EditingCheckpoint()
    var sidecarGeneration = 0

    init(loadWorkspace: Bool = true) {
        recoveryEnabled=loadWorkspace
        do { if loadWorkspace { workspace = try WorkflowStore.readWorkspace() } }
        catch { status = "照片库配置读取失败，已有文件未被改动" }
        do { try load(data: DemoImage.make(), name: "山间晨光", demo: true) }
        catch { errorMessage = error.localizedDescription }
    }
    var selectedMaskIndex: Int? { edits.masks.firstIndex { $0.id == selectedMaskID } }
    var selectedMask: LocalMask? { selectedMaskIndex.map { edits.masks[$0] } }
    var activeShape: MaskComponent? {
        guard let mask = selectedMask else { return nil }
        return mask.components.first(where: { $0.id == activeComponentID }) ?? mask.shape
    }
    var activeShapeKind: MaskKind? { activeShape?.kind }
    var canUndo: Bool { historyIndex > 0 || edits != history[historyIndex] }
    var canRedo: Bool { historyIndex < history.count - 1 }
    var isModified: Bool { newDocumentNeedsSave || documentStructureDirty || edits != (savedState ?? .init()) }
    var dimensions: String { "\(Int(sourceSize.width)) × \(Int(sourceSize.height))" }
    var selectedURLs: [URL] { workspace.library.filter { librarySelection.contains($0.id) }.map(\.url) }
    var editingLocked: Bool { recoveryPromptActive || isImporting || isStacking || batchRunning || isFindingRepairSource || isGeneratingMask }
    var isProcessingRepairs: Bool { isFindingRepairSource || (isRendering && edits.renderingState.repairs.contains { $0.enabled && $0.opacity > 0 && !$0.points.isEmpty }) }
    var repairProcessingTitle: String {
        if isFindingRepairSource { return "正在匹配取样区域…" }
        return edits.renderingState.repairs.contains { $0.mode == .inpaint } ? "正在移除内容…" : "正在计算修复…"
    }
    var fullResolutionPreview: Bool { zoom != 1 && zoom > fitZoom * 1.05 }
    func zoomBy(_ factor: Double) { zoom = min(800, max(2, (zoom == 1 ? fitZoom : zoom) * factor)) }

    func load(data: Data, name: String, demo: Bool = false, state: EditState = .init()) throws {
        let decoded = try PhotoIO.decode(data: data, fileExtension: URL(fileURLWithPath: name).pathExtension)
        adopt(decoded: decoded, data: data, name: name, demo: demo, state: state)
    }
    func adopt(decoded: DecodedPhoto, data: Data, name: String, demo: Bool = false, state: EditState = .init()) {
        generation += 1; renderWork?.cancel(); autosaveWork?.cancel()
        overlayGeneration += 1; overlayWork?.cancel(); maskOverlay=nil; isDrawingMask=false
        repairSearchGeneration+=1;isFindingRepairSource=false;repairDraft=[];selectedRepairID=nil;repairManualSource=nil;isPickingRepairSource=false
        automaticMaskGeneration += 1; isGeneratingMask = false; automaticMaskTask = nil
        recoveryWork?.cancel();presetBase=nil;presetTarget=nil;maskSelection=[];viewportCenter = .center
        documentID=UUID()
        source = decoded.image; imageMetadata = decoded.metadata
        sourceData = data; sourceDigest = WorkflowStore.digest(data)
        sourceName = name; sourceSize = decoded.image.extent.size
        isDemo = demo; sourceURL = nil; projectURL = nil
        edits = state; savedState = state; documentStructureDirty = false; newDocumentNeedsSave = false; history = [state]; historyIndex = 0
        snapshots = []; virtualCopies = []
        selectedMaskID = state.masks.first?.id; activeComponentID = nil
        sampleMode = .none; cropAspect = nil; zoom = 1; showBefore = false
        preview = nil; beforePreview = nil; previewPixelSize = .zero; maskOverlay = nil; beforeKey = nil
        pendingShapePlacement = false; captureCheckpoint()
        requestRender()
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = PhotoIO.supportedContentTypes + [UTType(filenameExtension: "luma") ?? .data]
        panel.allowsMultipleSelection = true
        panel.message = L("打开照片或项目；可多选加入照片库。支持位图、数字底片及系统支持的相机原始文件。")
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }
    func importFiles(_ urls: [URL]) {
        let supported = urls.filter { PhotoIO.supportedExtensions.contains($0.pathExtension.lowercased()) || $0.pathExtension.lowercased() == "luma" }
        guard let first = supported.first else { errorMessage = "未找到支持的图像文件。请拖入照片文件，而不是文件夹。"; return }
        addToLibrary(supported.filter { $0.pathExtension.lowercased() != "luma" })
        open(first)
    }
    func open(_ url: URL) {
        guard !editingLocked, confirmUnsavedChanges() else { return }
        importGeneration += 1; let ticket = importGeneration
        isImporting = true; status = "正在读取 \(url.lastPathComponent)…"
        ioQueue.async { [weak self] in
            do {
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                if url.pathExtension.lowercased() == "luma" {
                    let project = try JSONDecoder().decode(PhotoProject.self, from: data)
                    guard (1...2).contains(project.formatVersion) else { throw EditorError.unsupportedProject }
                    let decoded = try PhotoIO.decode(data: project.sourceData, fileExtension: URL(fileURLWithPath: project.sourceName).pathExtension)
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, self.importGeneration == ticket else { return }
                        self.adopt(decoded: decoded, data: project.sourceData, name: project.sourceName, state: project.edits)
                        self.projectURL = url; self.snapshots = project.snapshots; self.virtualCopies = project.virtualCopies
                        self.restoreHistory(project.history, current: project.edits)
                        self.captureCheckpoint()
                        self.isImporting = false; self.status = "项目已恢复"
                    }
                } else {
                    let decoded = try PhotoIO.decode(data: data, fileExtension: url.pathExtension)
                    var sidecar: SidecarDocument?
                    var warning: String?
                    do { sidecar = try PhotoSettingsStore.read(for: url, data: data) }
                    catch { warning = "\(error.localizedDescription) 未自动应用保存参数。" }
                    let saved = sidecar, notice = warning
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, self.importGeneration == ticket else { return }
                        self.adopt(decoded: decoded, data: data, name: url.lastPathComponent, state: saved?.edits ?? .init())
                        self.sourceURL = url
                        self.snapshots = saved?.snapshots ?? []; self.virtualCopies = saved?.virtualCopies ?? []
                        self.restoreHistory(saved?.history ?? [], current: self.edits)
                        self.captureCheckpoint()
                        self.addToLibrary([url]); self.isImporting = false
                        self.status = notice ?? (saved == nil ? "照片已打开 · \(decoded.metadata.decoderDescription)" : "已自动恢复保存的修改参数")
                        if let notice = notice { self.errorMessage = notice }
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.importGeneration == ticket else { return }
                    self.isImporting = false; self.errorMessage = error.localizedDescription; self.status = "读取失败，当前照片未改变"
                }
            }
        }
    }
    func restoreHistory(_ states: [EditState], current: EditState) {
        history = Array(states.suffix(79))
        if history.last != current { history.append(current) }
        if history.isEmpty { history = [current] }
        historyIndex = history.count - 1
    }
    func sidecarSnapshot() -> SidecarDocument {
        var states = Array(history.prefix(historyIndex + 1))
        if states.last != edits { states.append(edits) }
        return SidecarDocument(sourceSHA256: sourceDigest, sourceFilename: sourceName, edits: edits, snapshots: snapshots, virtualCopies: virtualCopies, history: Array(states.suffix(80)))
    }
    @discardableResult
    func saveProject() -> Bool {
        guard !editingLocked else { status = "请等待读取、合成或批处理完成后再保存"; return false }
        autosaveWork?.cancel(); sidecarGeneration += 1
        commit(persist: false)
        if let url = sourceURL {
            do {
                let document = sidecarSnapshot()
                let written=try ioQueue.sync { try PhotoSettingsStore.write(document,for:url,expectedData:sourceData) }
                sourceData=written;sourceDigest=WorkflowStore.digest(written)
                savedState = edits; documentStructureDirty = false; captureCheckpoint(); status = url.pathExtension.lowercased()=="dng" ? "修改参数已嵌入 DNG" : "修改已保存到 \(WorkflowStore.sidecarURL(for: url).lastPathComponent)"
                return true
            } catch { errorMessage = "修改参数保存失败：\(error.localizedDescription)"; return false }
        }
        return saveEmbeddedProject()
    }
    @discardableResult
    func saveEmbeddedProject() -> Bool {
        guard !editingLocked else { return false }
        commit(persist: false)
        var url = projectURL
        if url == nil {
            let panel = NSSavePanel(); panel.title = L("保存便携项目")
            panel.nameFieldStringValue = URL(fileURLWithPath: sourceName).deletingPathExtension().lastPathComponent + ".luma"
            panel.allowedContentTypes = [UTType(filenameExtension: "luma") ?? .data]
            guard panel.runModal() == .OK else { return false }; url = panel.url
        }
        guard let destination = url else { return false }
        do {
            let project = PhotoProject(sourceName: sourceName, sourceData: sourceData, edits: edits, snapshots: snapshots, virtualCopies: virtualCopies, history: Array(history.prefix(historyIndex + 1)))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(project).write(to: destination, options: .atomic)
            projectURL = destination; savedState = edits; documentStructureDirty = false; newDocumentNeedsSave = false; captureCheckpoint(); status = "便携项目已保存"
            clearRecovery();return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    // Only explicit Save writes image settings.
    func scheduleAutosave() {scheduleRecovery()}
    func persistSidecar() { documentStructureDirty = true; scheduleRecovery() }
    func captureCheckpoint() {
        checkpoint = EditingCheckpoint(edits:edits,snapshots:snapshots,virtualCopies:virtualCopies,
                                       history:history,historyIndex:historyIndex)
    }
    func cancelEditing() {
        guard !editingLocked else { return }
        autosaveWork?.cancel(); sidecarGeneration += 1
        repairSearchGeneration+=1;repairDraft=[];selectedRepairID=nil;repairManualSource=nil;isPickingRepairSource=false
        edits = checkpoint.edits; snapshots = checkpoint.snapshots; virtualCopies = checkpoint.virtualCopies
        history = checkpoint.history; historyIndex = checkpoint.historyIndex
        savedState = checkpoint.edits; documentStructureDirty = false; newDocumentNeedsSave = false
        selectedMaskID = edits.masks.first?.id; activeComponentID = nil; pendingShapePlacement = false
        requestRender(); status = "已取消未保存的修改，文件中的参数未改变"
    }
    @discardableResult
    func saveCurrentEdits() -> Bool {
        guard saveProject() else { return false }
        clearRecovery()
        if autoSyncSelection && selectedURLs.count > 1 { copiedSettings = edits; applyCopiedToSelection(committingCurrent:true) }
        return true
    }
    func finishEditing() { saveCurrentEdits() }
    func sectionVisible(_ section: AdjustmentSection, local: Bool = false) -> Bool {
        !(local ? (selectedMask?.disabledSections.contains(section) ?? false) : edits.disabledSections.contains(section))
    }
    func toggleSection(_ section: AdjustmentSection, local: Bool = false) {
        guard !editingLocked else { return }
        if local, let index = selectedMaskIndex {
            if edits.masks[index].disabledSections.contains(section) { edits.masks[index].disabledSections.remove(section) }
            else { edits.masks[index].disabledSections.insert(section) }
        } else if !local {
            if edits.disabledSections.contains(section) { edits.disabledSections.remove(section) }
            else { edits.disabledSections.insert(section) }
        }
        commit(); requestRender()
    }
    func resetSection(_ section: AdjustmentSection, local: Bool = false) {
        guard !editingLocked else { return }
        if local, let index = selectedMaskIndex {
            edits.masks[index].adjustments.reset(section)
            if section == .hsl { edits.masks[index].hsl=HSLBand.defaults }
        }
        else if !local { edits.reset(section) }
        commit(); requestRender()
    }
    func resetHSLBand(_ index: Int, local: Bool = false) {
        guard !editingLocked, HSLBand.defaults.indices.contains(index) else {return}
        if local, let maskIndex=selectedMaskIndex, edits.masks[maskIndex].hsl.indices.contains(index) { edits.masks[maskIndex].hsl[index]=HSLBand.defaults[index] }
        else if !local, edits.hsl.indices.contains(index) { edits.hsl[index]=HSLBand.defaults[index] }
        commit(); requestRender()
    }
    func confirmUnsavedChanges() -> Bool {
        guard isModified else {clearRecovery();return true}
        let alert = NSAlert(); alert.messageText = L("保存对“\(sourceName)”的修改？")
        alert.informativeText = L("保存调整、选区和裁剪参数；不会重新编码原始图像像素。")
        alert.addButton(withTitle: L("保存修改")); alert.addButton(withTitle: L("不保存")); alert.addButton(withTitle: L("取消"))
        switch alert.runModal() { case .alertFirstButtonReturn: return saveCurrentEdits(); case .alertSecondButtonReturn: clearRecovery();return true; default: return false }
    }

    func editBinding<T>(_ key: WritableKeyPath<EditState, T>) -> Binding<T> {
        Binding(get: { self.edits[keyPath: key] }, set: { guard !self.editingLocked else { return }; self.edits[keyPath: key] = $0; self.requestRender() })
    }
    func adjustment(_ key: WritableKeyPath<Adjustments, Double>, local: Bool = false) -> Binding<Double> {
        Binding(get: { local ? (self.selectedMask?.adjustments[keyPath: key] ?? 0) : self.edits.adjustments[keyPath: key] }, set: { value in
            guard !self.editingLocked else { return }
            if local { guard let index = self.selectedMaskIndex else { return }; self.edits.masks[index].adjustments[keyPath: key] = value }
            else { self.edits.adjustments[keyPath: key] = value }
            self.requestRender()
        })
    }
    func maskValue(_ key: WritableKeyPath<LocalMask, Double>) -> Binding<Double> {
        Binding(get: { self.selectedMask?[keyPath: key] ?? 0 }, set: { value in
            guard let index = self.selectedMaskIndex else { return }; self.edits.masks[index][keyPath: key] = value; self.requestRender()
        })
    }
    func maskShapeValue(_ key: WritableKeyPath<MaskComponent, Double>) -> Binding<Double> {
        Binding(get: { self.activeShape?[keyPath: key] ?? 0 }, set: { value in self.updateActiveShape { $0[keyPath: key] = value }; self.requestRender() })
    }
    func maskName() -> Binding<String> {
        Binding(get: { self.selectedMask?.name ?? "" }, set: { name in guard let i = self.selectedMaskIndex else { return }; self.edits.masks[i].name = name; self.scheduleAutosave() })
    }
    func updateActiveShape(_ body: (inout MaskComponent) -> Void) {
        guard let i = selectedMaskIndex else { return }
        if let id = activeComponentID, let k = edits.masks[i].components.firstIndex(where: { $0.id == id }) { body(&edits.masks[i].components[k]) }
        else { var shape = edits.masks[i].shape; body(&shape); edits.masks[i].shape = shape }
    }
    func selectComponent(id: UUID?) { pendingShapePlacement = false; activeComponentID = id; sampleMode = .none; requestRender() }
    func addComponent(kind: MaskKind, operation: MaskOperation) {
        guard let i = selectedMaskIndex else { return }
        let component = MaskComponent(kind: kind, operation: operation)
        edits.masks[i].components.append(component); activeComponentID = component.id
        pendingShapePlacement = [.linear,.radial,.rectangle].contains(kind)
        if kind == .colorRange { sampleMode = .maskColor }
        if kind == .luminanceRange { sampleMode = .maskLuminance }
        commit(); requestRender()
    }
    func removeComponent(id: UUID) {
        guard let i = selectedMaskIndex else { return }
        edits.masks[i].components.removeAll { $0.id == id }; activeComponentID = nil; commit(); requestRender()
    }

    func requestMaskOverlay() {
        overlayWork?.cancel(); overlayGeneration += 1
        let ticket = overlayGeneration
        let layers = overlayMasks
        let coverageMask = coveragePreviewEnabled ? selectedMask : nil
        guard tool == .masks, let source, (!layers.isEmpty || coverageMask != nil) else { maskOverlay = nil; coverageImage = nil; return }
        // A separate renderer/queue keeps feedback responsive during a slow photo render.
        let job = DispatchWorkItem { [weak self, overlayRenderer] in
            do {
                let overlay = try overlayRenderer.selectionOverlays(layers, source: source, maxDimension: 1600)
                let coverage = try coverageMask.map {try overlayRenderer.coveragePreview($0,source:source)}
                DispatchQueue.main.async {
                    guard let self, self.overlayGeneration == ticket else { return }
                    self.coverageImage = coverage
                    self.maskOverlay = overlay
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.overlayGeneration == ticket else { return }
                    self.maskOverlay = nil
                }
            }
        }
        overlayWork = job; overlayQueue.async(execute: job)
    }
    func requestRender() {
        requestMaskOverlay()
        guard let source = source else { return }
        if isModified && !isImporting && !isStacking && !batchRunning { status = "有未保存修改，按 ⌘S 或点击保存" }
        renderWork?.cancel(); generation += 1; let ticket = generation
        var snapshot = edits.renderingState
        if tool == .masks || tool == .repair { snapshot.quarterTurns = 0; snapshot.flipHorizontal = false; snapshot.crop = .full; snapshot.geometry = .init() }
        let proof=proofOptions
        let applyCrop = tool != .crop
        let limit: CGFloat? = fullResolutionPreview && !isDrawingMask ? nil : 1600
        var before = EditState(); before.quarterTurns = snapshot.quarterTurns; before.flipHorizontal = snapshot.flipHorizontal
        before.crop = snapshot.crop; before.geometry = snapshot.geometry; before.adjustments.distortion = snapshot.adjustments.distortion
        let cachedOriginal = beforeKey == before && beforeLimit == limit && beforeApplyCrop == applyCrop ? beforePreview : nil
        isRendering = true
        let job = DispatchWorkItem { [weak self, renderer] in
            do {
                let pixelSize = try renderer.outputSize(source:source,edits:snapshot,applyCrop:applyCrop)
                let raw = try proof.enabled ? renderer.proofSource(source:source,edits:snapshot,maxDimension:limit,applyCrop:applyCrop):renderer.render(source: source, edits: snapshot, maxDimension: limit, applyCrop: applyCrop)
                let cg = try SoftProof.render(raw,options:proof)
                let original = try cachedOriginal ?? renderer.render(source: source, edits: before, maxDimension: limit, applyCrop: applyCrop)
                let bins = renderer.histogram(cg)
                DispatchQueue.main.async {
                    guard let self = self, self.generation == ticket else { return }
                    self.preview = cg; self.beforePreview = original; self.previewPixelSize = pixelSize; self.beforeKey = before; self.beforeLimit = limit
                    self.beforeApplyCrop = applyCrop
                    self.histogram = bins; self.isRendering = false
                }
            } catch { DispatchQueue.main.async { guard let self = self, self.generation == ticket else { return }; self.isRendering = false; self.errorMessage = error.localizedDescription } }
        }
        renderWork = job; renderQueue.asyncAfter(deadline: .now() + 0.045, execute: job)
        scheduleAutosave()
    }
    func commit(persist: Bool = true) {
        guard history[historyIndex] != edits else { if persist { scheduleAutosave() }; return }
        history = Array(history.prefix(historyIndex + 1)); history.append(edits)
        if history.count > 80 { history.removeFirst() }; historyIndex = history.count - 1
        if persist {
            scheduleAutosave()
        }
    }
    func undo() { guard !editingLocked else { return }; pendingShapePlacement=false; selectedRepairID=nil; if edits != history[historyIndex] { edits = history[historyIndex] } else if historyIndex > 0 { historyIndex -= 1; edits = history[historyIndex] }; selectedMaskID = edits.masks.first?.id; activeComponentID = nil; status = "已撤销"; requestRender() }
    func redo() { guard !editingLocked, canRedo else { return }; pendingShapePlacement=false; selectedRepairID=nil; historyIndex += 1; edits = history[historyIndex]; selectedMaskID = edits.masks.first?.id; activeComponentID = nil; status = "已重做"; requestRender() }
    func reset() { edits = .init(); selectedMaskID = nil; commit(); requestRender(); status = "全部调整已重置" }
    func resetAdjustments(local: Bool) {
        if local, let i = selectedMaskIndex { edits.masks[i].adjustments = .neutral; edits.masks[i].hsl=HSLBand.defaults }
        else if !local { edits.adjustments = .neutral }
        commit(); requestRender()
    }
    func addMask(_ kind: MaskKind) {
        let mask = LocalMask(name: "\(kind.title) \(edits.masks.count + 1)", kind: kind)
        edits.masks.append(mask); selectedMaskID = mask.id; activeComponentID = nil; tool = .masks
        pendingShapePlacement = [.linear,.radial,.rectangle].contains(kind)
        if kind == .colorRange { sampleMode = .maskColor }
        if kind == .luminanceRange { sampleMode = .maskLuminance }
        commit(); requestRender(); status = kind == .brush ? "在照片上涂抹，同一画笔层的重叠区域不会累计强度" : "在照片上拖动，调整选区位置与大小"
    }
    func deleteMask() { edits.masks.removeAll { $0.id == selectedMaskID }; selectedMaskID = edits.masks.last?.id; activeComponentID = nil; commit(); requestRender() }
    func duplicateMask() { guard var mask = selectedMask else { return }; mask.id = UUID(); mask.name += " 副本"; edits.masks.append(mask); selectedMaskID = mask.id; activeComponentID = nil; commit(); requestRender() }
    func toggleMask(_ id: UUID) { guard let i = edits.masks.firstIndex(where: { $0.id == id }) else { return }; edits.masks[i].enabled.toggle(); commit(); requestRender() }
    func invertMask() { guard let i = selectedMaskIndex else { return }; edits.masks[i].inverted.toggle(); commit(); requestRender() }
    func clearBrush() { updateActiveShape { $0.strokes = []; $0.erasedStrokes = []; $0.edgeStrokes=[] }; commit(); requestRender() }
    func rotate() { edits.quarterTurns = (edits.quarterTurns + 1) % 4; edits.crop = .full; commit(); requestRender() }
    func flip() { edits.flipHorizontal.toggle(); commit(); requestRender() }
    func resetCrop() { edits.crop = .full; cropAspect = nil; commit(); requestRender() }
    func applyCropAspect(_ ratio: Double?) {
        cropAspect = ratio
        guard let ratio = ratio, let image = preview, ratio > 0 else { return }
        let normalized = ratio / (Double(image.width) / Double(image.height))
        let width = min(1.0, normalized), height = min(1.0, 1 / normalized)
        edits.crop = CropRegion(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
        commit(); requestRender()
    }
    func applyPreset(_ name: String) {
        let base=edits
        var a = Adjustments()
        switch name {
        case "柔和日光", "Soft daylight": a.exposure = 0.2; a.contrast = -12; a.highlights = -30; a.shadows = 24; a.temperature = 12; a.vibrance = 18
        case "电影色调", "Cinematic": a.contrast = 22; a.highlights = -28; a.shadows = 14; a.temperature = -12; a.saturation = -20; a.vignette = 24
        case "黑白", "Silver": a.saturation = -100; a.contrast = 24; a.highlights = -15; a.shadows = 16; a.clarity = 12
        default: break
        }
        edits.adjustments = a; beginPresetAmount(base:base,target:edits); commit(); requestRender(); status = "已应用\(name)"
    }
    func sample(at point: UnitPoint2D) {
        guard let image = beforePreview, sampleMode != .none else { return }
        let px = min(max(Int(point.x * Double(image.width)), 0), image.width - 1)
        let py = min(max(Int(point.y * Double(image.height)), 0), image.height - 1)
        // Crop in CGImage's top-left raster coordinates, then sample its color-managed RGB.
        guard let patch = image.cropping(to: CGRect(x: px, y: py, width: 1, height: 1)) else { return }
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(patch, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let rgb = pixel.prefix(3).map { Double($0) / 255 }
        switch sampleMode {
        case .whiteBalance:
            edits.adjustments.temperature = min(100, max(-100, (rgb[2] - rgb[0]) * 120))
            edits.adjustments.tint = min(100, max(-100, (rgb[1] - (rgb[0] + rgb[2]) / 2) * 150))
        case .pointColor: edits.pointColor.enabled = true; edits.pointColor.color = rgb
        case .maskColor: updateActiveShape { $0.rangeColor = rgb }
        case .maskLuminance:
            let l = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
            updateActiveShape { $0.luminanceLow = max(0, l - 0.15); $0.luminanceHigh = min(1, l + 0.15) }
        case .none: break
        }
        sampleMode = .none; commit(); requestRender(); status = "已从照片采样"
    }
}

enum EditorError: LocalizedError {
    case unsupportedProject, unsupportedImage
    var errorDescription: String? { switch self { case .unsupportedProject: return "暂不支持这个项目版本。"; case .unsupportedImage: return "暂时无法读取这个图像。原始文件的支持范围取决于系统解码器。" } }
}
