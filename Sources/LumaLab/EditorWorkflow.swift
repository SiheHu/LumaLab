import LumaDomain
import AppKit
import SwiftUI
import CoreImage
import ImageIO
import UniformTypeIdentifiers

extension EditorModel {
    func addToLibrary(_ urls: [URL]) {
        let existing = Set(workspace.library.map(\.path))
        for url in urls where !existing.contains(url.path) && !workspace.library.contains(where: { $0.path == url.path }) {
            workspace.library.append(PhotoLibraryItem(path: url.path))
        }
        if let first = urls.first { librarySelection = [first.path] }
        persistWorkspace()
    }
    func persistWorkspace() {
        let value = workspace
        ioQueue.async { [weak self] in
            do { try WorkflowStore.writeWorkspace(value) }
            catch { DispatchQueue.main.async { [weak self] in self?.errorMessage = "照片库配置保存失败：\(error.localizedDescription)" } }
        }
    }
    func updateLibrary(_ path: String, rating: Int? = nil, flag: Int? = nil, keywords: String? = nil, collection: String? = nil) {
        guard let i = workspace.library.firstIndex(where: { $0.path == path }) else { return }
        if let rating = rating { workspace.library[i].rating = rating }
        if let flag = flag { workspace.library[i].flag = flag }
        if let keywords = keywords { workspace.library[i].keywords = keywords }
        if let collection = collection { workspace.library[i].collection = collection }
        persistWorkspace()
    }
    func removeFromLibrary(_ paths: Set<String>) {
        workspace.library.removeAll { paths.contains($0.path) }; librarySelection.subtract(paths)
        persistWorkspace(); status = "已从照片库移除引用，原始文件未删除"
    }
    func saveUserPreset(name: String, category:String = "自定义", author:String = "") {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var preset=UserPreset(name:clean,state:edits)
        preset.category=category.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? "自定义":String(category.prefix(80))
        preset.author=String(author.prefix(120))
        workspace.presets.append(preset); persistWorkspace(); status = "预设已保存"
    }
    func applyUserPreset(_ preset: UserPreset, includeGeometry: Bool = false, includeMasks: Bool = false) {
        let base=edits
        edits = mergedSettings(preset.state, into: edits, color: true, geometry: includeGeometry, masks: includeMasks)
        beginPresetAmount(base:base,target:edits)
        commit(); requestRender(); status = "已应用预设：\(preset.name)"
    }
    func deleteUserPreset(_ id: UUID) { workspace.presets.removeAll { $0.id == id }; persistWorkspace() }
    func saveExportPreset(name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines); guard !clean.isEmpty else { return }
        workspace.exportPresets.append(ExportPreset(name: clean, options: exportOptions)); persistWorkspace()
    }
    func copySettings() { commit(); copiedSettings = edits; status = "已复制调整参数" }
    func pasteSettings() {
        guard !editingLocked else { return }
        guard let copied = copiedSettings else { return }
        edits = mergedSettings(copied, into: edits, color: batchColor, geometry: batchGeometry, masks: batchMasks)
        commit(); requestRender(); status = "已粘贴所选类型的参数"
    }
    func addSnapshot(name: String) {
        guard !editingLocked else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        snapshots.append(SavedSnapshot(name: clean.isEmpty ? "快照 \(snapshots.count + 1)" : clean, state: edits))
        documentStructureDirty = true; persistSidecar(); status = "快照已加入本次修改，按 ⌘S 保存"
    }
    func restoreSnapshot(_ snapshot: SavedSnapshot) { guard !editingLocked else { return }; edits = snapshot.state; commit(); requestRender(); status = "已恢复：\(snapshot.name)" }
    func deleteSnapshot(_ id: UUID) { snapshots.removeAll { $0.id == id }; documentStructureDirty = true; persistSidecar() }
    func createVirtualCopy(name: String) {
        guard !editingLocked else { return }
        if virtualCopies.isEmpty { virtualCopies.append(SavedSnapshot(name: "主版本", state: edits)) }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        virtualCopies.append(SavedSnapshot(name: clean.isEmpty ? "虚拟副本 \(virtualCopies.count)" : clean, state: edits))
        documentStructureDirty = true; persistSidecar(); status = "虚拟副本已创建，未复制原始图像"
    }
    func updateVirtualCopy(_ id: UUID) {
        guard let i = virtualCopies.firstIndex(where: { $0.id == id }) else { return }
        virtualCopies[i].state = edits; documentStructureDirty = true; persistSidecar(); status = "已将当前调整保存到副本"
    }
    func deleteVirtualCopy(_ id: UUID) { virtualCopies.removeAll { $0.id == id }; documentStructureDirty = true; persistSidecar() }
    func restoreHistoryIndex(_ index: Int) {
        guard history.indices.contains(index) else { return }; historyIndex = index; edits = history[index]
        selectedMaskID = edits.masks.first?.id; activeComponentID = nil; requestRender(); status = "已恢复历史步骤 \(index + 1)"
    }

    func applyCopiedToSelection(committingCurrent: Bool = false) {
        guard let copied = copiedSettings, !selectedURLs.isEmpty, !editingLocked else { return }
        let urls = selectedURLs; let color = batchColor, geometry = batchGeometry, masks = batchMasks
        let adaptive=adaptiveBatchMasks
        let currentURL = sourceURL, currentAtStart = edits, currentDocument = sidecarSnapshot()
        if let currentURL = currentURL, urls.contains(currentURL) { autosaveWork?.cancel(); sidecarGeneration += 1 }
        batchRunning = true
        ioQueue.async { [weak self] in
            var updatedCurrentData:Data?
            var succeeded = 0; var failures: [String] = []; var successPaths = Set<String>()
            for url in urls {
                do {
                    let data = try Data(contentsOf: url)
                    var doc: SidecarDocument
                    if url == currentURL {
                        guard WorkflowStore.digest(data) == currentDocument.sourceSHA256 else { throw WorkflowStore.StoreError.sourceChanged }
                        doc = currentDocument
                    } else {
                        doc = try PhotoSettingsStore.read(for: url, data: data) ?? SidecarDocument(sourceSHA256: WorkflowStore.digest(data), sourceFilename: url.lastPathComponent, edits: .init())
                    }
                    doc.edits = mergedSettings(copied, into: doc.edits, color: color, geometry: geometry, masks: masks)
                    if masks && adaptive && url != currentURL {
                        doc.edits = try AdaptiveMaskSync.refresh(doc.edits,data:data,fileExtension:url.pathExtension)
                    }
                    doc.history.append(doc.edits); doc.history = Array(doc.history.suffix(80)); doc.updatedAt = Date()
                    if url != currentURL || committingCurrent {let written=try PhotoSettingsStore.write(doc,for:url,expectedData:data);if url==currentURL {updatedCurrentData=written}}
                    succeeded += 1; successPaths.insert(url.path)
                } catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
            }
            let count = succeeded, errors = failures, writtenPaths = successPaths, writtenCurrent=updatedCurrentData
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }; self.batchRunning = false
                self.status = "已处理 \(count) 张照片" + ((!committingCurrent && currentURL.map {writtenPaths.contains($0.path)} == true) ? "，当前照片按 ⌘S 保存" : "，参数已保存")
                if let current = self.sourceURL, current == currentURL, writtenPaths.contains(current.path) {
                    if self.edits == currentAtStart {
                        self.edits = mergedSettings(copied, into: self.edits, color: color, geometry: geometry, masks: masks)
                        self.commit(persist:false)
                        if committingCurrent {if let data=writtenCurrent {self.sourceData=data;self.sourceDigest=WorkflowStore.digest(data)};self.savedState=self.edits;self.captureCheckpoint()}
                        self.requestRender()
                    } else {
                        self.scheduleAutosave()
                        // Current editing stays pending until an explicit Done / Save.
                    }
                }
                if !errors.isEmpty { self.errorMessage = "部分照片未成功：\n" + errors.joined(separator: "\n") }
            }
        }
    }

    func exportImage(png: Bool) { exportOptions.format = png ? .png : .jpeg; showExport = true }
    func exportCurrent() {
        guard let source = source, !isExporting, !editingLocked else { return }
        let options = exportOptions
        let panel = NSSavePanel(); panel.title = L("导出照片")
        panel.allowedContentTypes = [options.format == .png ? .png : options.format == .tiff ? .tiff : .jpeg]
        panel.nameFieldStringValue = URL(fileURLWithPath: sourceName).deletingPathExtension().lastPathComponent + "-调整后." + options.format.fileExtension
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        if [sourceURL, projectURL].compactMap({ $0 }).contains(where: { $0.standardizedFileURL.resolvingSymlinksInPath() == resolved }) {
            errorMessage = "导出文件不能覆盖原始照片或正在编辑的项目，请选择新的文件名。"
            return
        }
        let state = edits
        var metadata = imageMetadata?.properties ?? [:]
        if let item = workspace.library.first(where: { $0.path == sourceURL?.path }), !item.keywords.isEmpty {
            var iptc = metadata[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]
            iptc[kCGImagePropertyIPTCKeywords as String] = item.keywords.split(whereSeparator: { $0 == "," || $0 == "，" }).map { String($0).trimmingCharacters(in: .whitespaces) }
            metadata[kCGImagePropertyIPTCDictionary as String] = iptc
        }
        let properties = metadata
        isExporting = true; status = "正在导出原始分辨率照片…"
        renderQueue.async { [weak self, renderer] in
            do {
                let data = try renderer.export(source: source, edits: state, options: options, metadata: properties)
                try data.write(to: url, options: .atomic)
                DispatchQueue.main.async { [weak self] in self?.isExporting = false; self?.showExport = false; self?.status = "已导出 \(url.lastPathComponent)" }
            } catch { DispatchQueue.main.async { [weak self] in self?.isExporting = false; self?.errorMessage = error.localizedDescription } }
        }
    }
    func batchExport() {
        let urls = selectedURLs; guard !urls.isEmpty, !editingLocked else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.message = L("选择批量导出的目标文件夹；不会覆盖已有文件。")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let options = exportOptions
        let currentURL = sourceURL, currentState = edits, currentDigest = sourceDigest
        batchRunning = true; isExporting = true
        ioQueue.async { [weak self, renderer] in
            var completed = 0; var failures: [String] = []
            for url in urls {
                do {
                    let data = try Data(contentsOf: url)
                    let decoded = try PhotoIO.decode(data: data, fileExtension: url.pathExtension)
                    let state: EditState
                    if url == currentURL {
                        guard WorkflowStore.digest(data) == currentDigest else { throw WorkflowStore.StoreError.sourceChanged }
                        state = currentState
                    } else {
                        state = try PhotoSettingsStore.read(for: url, data: data)?.edits ?? .init()
                    }
                    let name = url.deletingPathExtension().lastPathComponent + "-调整后"
                    var target = folder.appendingPathComponent(name).appendingPathExtension(options.format.fileExtension)
                    var index = 1
                    while FileManager.default.fileExists(atPath: target.path) {
                        target = folder.appendingPathComponent("\(name)-\(index)").appendingPathExtension(options.format.fileExtension); index += 1
                    }
                    let result = try renderer.export(source: decoded.image, edits: state, options: options, metadata: decoded.metadata.properties)
                    try result.write(to: target, options: .atomic); completed += 1
                } catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
            }
            let count = completed, errors = failures
            DispatchQueue.main.async { [weak self] in
                self?.batchRunning = false; self?.isExporting = false; self?.status = "批量导出完成：\(count) 张"
                if !errors.isEmpty { self?.errorMessage = errors.joined(separator: "\n") }
            }
        }
    }

    func chooseStackFiles() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = PhotoIO.supportedContentTypes
        panel.allowsMultipleSelection = true; panel.message = L("选择同一场景的多张照片，用于降噪、星轨或曝光融合。")
        if panel.runModal() == .OK { stackURLs = panel.urls }
    }
    func runStack() {
        guard !editingLocked, stackURLs.count >= 2, confirmUnsavedChanges() else { return }
        let urls = stackURLs, mode = stackMode, align = alignStack
        let rotation=rotationStack,deghost=stackDeghost,sigma=Float(stackSigma)
        isStacking = true; stackProgress = 0; status = "正在合成照片…"
        ioQueue.async { [weak self, renderer] in
            do {
                let result = try StackProcessor.combine(urls: urls, mode: mode, align: align, rotation:rotation, deghost:deghost, sigma:sigma) { fraction in
                    DispatchQueue.main.async { [weak self] in self?.stackProgress = fraction }
                }
                var options = ExportOptions(); options.format = .tiff; options.bitDepth = 16
                let bytes = try renderer.export(source: result.image, edits: .init(), options: options)
                let decoded = try PhotoIO.decode(data: bytes, fileExtension: "tiff")
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.adopt(decoded: decoded, data: bytes, name: "\(mode.title)-合成.tiff")
                    self.savedState = nil; self.newDocumentNeedsSave = true; self.isStacking = false; self.showStack = false
                    self.status = result.report
                }
            } catch { DispatchQueue.main.async { [weak self] in self?.isStacking = false; self?.errorMessage = error.localizedDescription; self?.status = "堆栈未完成，当前照片未改变" } }
        }
    }
}

extension EditorModel {
    func importUserPreset() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.message = L("选择 LumaLab 调整预设")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { var preset = try JSONDecoder().decode(UserPreset.self, from: Data(contentsOf: url)); preset.id = UUID(); workspace.presets.append(preset); persistWorkspace(); status = "预设已导入" }
        catch { errorMessage = "无法读取这个预设：\(error.localizedDescription)" }
    }
    func exportUserPreset(_ preset: UserPreset) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = preset.name + ".luma-preset.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(preset).write(to: url, options: .atomic); status = "预设已导出" }
        catch { errorMessage = error.localizedDescription }
    }
}
