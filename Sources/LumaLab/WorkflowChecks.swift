import LumaDomain
import Foundation

/// Uses only generated temporary fixtures. Never reads or writes the user's workspace.
enum WorkflowChecks {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { "工作流检查失败：\(message)" }
    }
    static func run() throws -> String {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw Failure(message: message) }
            assertions += 1
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LumaLab-workflow-checks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("fixture.jpg")
        let original = Data("immutable source fixture".utf8)
        try original.write(to: source)
        let missing = try WorkflowStore.readSidecar(for: source, data: original)
        try check(missing == nil, "没有旁车文件时正常返回空值")
        try check(WorkflowStore.sidecarURL(for: source).lastPathComponent == "fixture.jpg.luma.json", "旁车文件保留原扩展名")
        try check(WorkflowStore.digest(original).count == 64 && WorkflowStore.digest(original) != WorkflowStore.digest(Data("other".utf8)), "来源指纹具有区分度")

        var state = EditState()
        state.adjustments.exposure = 0.7
        state.adjustments.texture = 30
        state.adjustments.grain = 16
        state.geometry.angle = 1.5
        state.curves.master[2].y = 0.62
        state.hsl[0].saturation = -20
        state.grading.highlights.hue = 45
        state.grading.highlights.saturation = 22
        state.pointColor.enabled = true
        state.pointColor.color = [0.4, 0.6, 0.2]
        state.calibration.redHue = 12
        var mask = LocalMask(name: "天空", kind: .luminanceRange)
        mask.adjustments.highlights = -35
        mask.erasedStrokes = [[UnitPoint2D(x: 0.1, y: 0.2), UnitPoint2D(x: 0.3, y: 0.4)]]
        mask.flow = 0.45; mask.density = 0.6
        mask.components = [MaskComponent(kind: .radial, operation: .subtract)]
        state.masks = [mask]
        state.crop = CropRegion(x: 0.1, y: 0.2, width: 0.6, height: 0.7)
        state.quarterTurns = 1; state.flipHorizontal = true
        let snapshot = SavedSnapshot(name: "调整前", state: .init())
        let virtual = SavedSnapshot(name: "暖色版本", state: state)
        let sidecar = SidecarDocument(sourceSHA256: WorkflowStore.digest(original), sourceFilename: source.lastPathComponent,
                                      edits: state, snapshots: [snapshot], virtualCopies: [virtual], history: [.init(), state])
        try WorkflowStore.writeSidecar(sidecar, for: source)
        guard let restored = try WorkflowStore.readSidecar(for: source, data: original) else { throw Failure(message: "旁车文件没有恢复") }
        try check(restored.edits == state, "旁车文件恢复完整调整与选区组合")
        try check(restored.snapshots == [snapshot] && restored.virtualCopies == [virtual] && restored.history == [.init(), state], "旁车文件保留快照、虚拟副本与历史")
        let stillOriginal = try Data(contentsOf: source)
        try check(stillOriginal == original, "写入旁车文件不改变原始文件")
        var rejectedWrongSource = false
        do { _ = try WorkflowStore.readSidecar(for: source, data: Data("changed photo bytes".utf8)) }
        catch WorkflowStore.StoreError.sourceChanged { rejectedWrongSource = true }
        try check(rejectedWrongSource, "相同文件名但来源内容不同，不自动套用参数")
        var invalidVersion = sidecar; invalidVersion.version = 999
        try WorkflowStore.writeSidecar(invalidVersion, for: source)
        var rejectedVersion = false
        do { _ = try WorkflowStore.readSidecar(for: source, data: original) }
        catch WorkflowStore.StoreError.version { rejectedVersion = true }
        try check(rejectedVersion, "未知旁车版本明确拒绝")
        let damaged = Data("{\"bad json".utf8)
        try damaged.write(to: WorkflowStore.sidecarURL(for: source))
        var rejectedCorruption = false
        do { _ = try WorkflowStore.readSidecar(for: source, data: original) } catch { rejectedCorruption = true }
        try check(rejectedCorruption, "损坏旁车文件报告错误")
        let preservedDamaged = try Data(contentsOf: WorkflowStore.sidecarURL(for: source))
        try check(preservedDamaged == damaged, "读取失败不覆盖原旁车文件")

        // A real v1-shaped JSON object omits every v2 field, including mask fields.
        let legacyJSON: [String: Any] = [
            "formatVersion": 1, "sourceName": "legacy.jpg", "sourceData": original.base64EncodedString(),
            "edits": ["adjustments": ["exposure": 0.5, "contrast": 12],
                      "masks": [["name": "旧画笔", "kind": "brush", "adjustments": ["exposure": 0.3]]],
                      "quarterTurns": 1]
        ]
        let legacy = try JSONDecoder().decode(PhotoProject.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        try check(legacy.formatVersion == 1 && legacy.sourceData == original, "旧项目保留来源数据")
        try check(legacy.edits.adjustments.exposure == 0.5 && legacy.edits.adjustments.contrast == 12 && legacy.edits.quarterTurns == 1, "旧项目保留已有参数")
        try check(legacy.edits.adjustments.texture == 0 && legacy.edits.geometry == GeometrySettings(), "旧项目新增参数使用中性默认值")
        try check(legacy.edits.curves == CurveSettings() && legacy.edits.hsl == HSLBand.defaults && legacy.edits.calibration == CalibrationSettings(), "旧项目曲线与色彩默认值")
        try check(legacy.snapshots.isEmpty && legacy.virtualCopies.isEmpty && legacy.history.isEmpty, "旧项目缺少工作流字段时使用空列表")
        try check(legacy.edits.masks.first?.flow == 1 && legacy.edits.masks.first?.density == 1 && legacy.edits.masks.first?.components.isEmpty == true, "旧画笔迁移保留覆盖方式")
        let project = PhotoProject(sourceName: "fixture.jpg", sourceData: original, edits: state, snapshots: [snapshot], virtualCopies: [virtual], history: [.init(), state])
        let restoredProject = try JSONDecoder().decode(PhotoProject.self, from: JSONEncoder().encode(project))
        try check(restoredProject.formatVersion == 2 && restoredProject.sourceData == original, "新项目版本与来源完整往返")
        try check(restoredProject.edits == state && restoredProject.history == [.init(), state], "新项目调整与历史完整往返")
        try check(restoredProject.snapshots == [snapshot] && restoredProject.virtualCopies == [virtual], "新项目快照与虚拟副本完整往返")
        let workspace = WorkspaceData(library: [PhotoLibraryItem(path: source.path, rating: 4, flag: 1, keywords: "风景, 冬天", collection: "旅程")],
                                      presets: [UserPreset(name: "柔和", state: state)],
                                      exportPresets: [ExportPreset(name: "网络交付", options: ExportOptions(format: .jpeg, quality: 0.85, longEdge: 2048, watermark: "摄影者"))])
        // Serialization is the persistence boundary; do not call writeWorkspace()
        // because its destination belongs to the user's actual account.
        let restoredWorkspace = try JSONDecoder().decode(WorkspaceData.self, from: JSONEncoder().encode(workspace))
        try check(restoredWorkspace.library == workspace.library, "工作区保存路径、评分、标记、关键词与收藏")
        try check(restoredWorkspace.presets.first?.state == state && restoredWorkspace.presets.first?.id == workspace.presets.first?.id, "工作区保存用户预设")
        try check(restoredWorkspace.exportPresets.first?.options == workspace.exportPresets.first?.options, "工作区保存导出预设")
        try check(restoredWorkspace.exportPresets.first?.id == workspace.exportPresets.first?.id, "工作区保留导出预设标识")
        let emptyWorkspace = try JSONDecoder().decode(WorkspaceData.self, from: JSONEncoder().encode(WorkspaceData()))
        try check(emptyWorkspace.library.isEmpty && emptyWorkspace.presets.isEmpty && emptyWorkspace.exportPresets.isEmpty, "空工作区往返")
        var destination = EditState()
        destination.adjustments.exposure = -1
        destination.geometry.angle = -2
        destination.crop = CropRegion(x: 0.2, y: 0.1, width: 0.4, height: 0.5)
        destination.masks = [LocalMask(name: "原选区", kind: .brush)]
        for bits in 0..<8 {
            let color = bits & 1 != 0, geometry = bits & 2 != 0, masks = bits & 4 != 0
            let merged = mergedSettings(state, into: destination, color: color, geometry: geometry, masks: masks)
            try check(merged.adjustments == (color ? state.adjustments : destination.adjustments), "选择性复制的基础调整组 \(bits)")
            try check(merged.curves == (color ? state.curves : destination.curves) && merged.hsl == (color ? state.hsl : destination.hsl), "选择性复制的曲线与色彩组 \(bits)")
            try check(merged.pointColor == (color ? state.pointColor : destination.pointColor) && merged.calibration == (color ? state.calibration : destination.calibration) && merged.grading == (color ? state.grading : destination.grading), "选择性复制的高级色彩组 \(bits)")
            try check(merged.crop == (geometry ? state.crop : destination.crop) && merged.geometry == (geometry ? state.geometry : destination.geometry) && merged.quarterTurns == (geometry ? state.quarterTurns : destination.quarterTurns) && merged.flipHorizontal == (geometry ? state.flipHorizontal : destination.flipHorizontal), "选择性复制的几何组 \(bits)")
            try check(merged.masks == (masks ? state.masks : destination.masks), "选择性复制的选区组 \(bits)")
        }
        return "通过 — \(assertions) 项工作流检查（旧项目迁移、来源指纹、旁车恢复、工作区、预设、快照与选择性复制）。"
    }
}
