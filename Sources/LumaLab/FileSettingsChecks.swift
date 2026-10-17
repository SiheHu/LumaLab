import LumaDomain
import Foundation

@MainActor enum FileSettingsChecks {
    static func run() throws -> String {
        let fixture=ProcessInfo.processInfo.environment["LUMALAB_DNG_FIXTURE"].map {URL(fileURLWithPath:$0)}
        guard let fixture,FileManager.default.fileExists(atPath:fixture.path) else {return "File settings checks: real DNG fixture unavailable; integration checks skipped."}
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("LumaLab-FileSettings-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);defer {try? FileManager.default.removeItem(at:folder)}
        var count=0
        func check(_ condition:Bool,_ message:String) throws {guard condition else {throw RepairChecks.Failure(message:message)};count+=1}
        let original=try Data(contentsOf:fixture),file=folder.appendingPathComponent("sample.dng")
        try original.write(to:file)
        let model=EditorModel(loadWorkspace:false)
        try model.load(data:original,name:"sample.dng");model.sourceURL=file
        var repair=RepairStroke();repair.points=[UnitPoint2D(x:0.4,y:0.4)];repair.source=UnitPoint2D(x:0.5,y:0.5)
        model.edits.repairs=[repair];model.edits.adjustments.exposure=0.5;model.commit()
        RunLoop.current.run(until:Date().addingTimeInterval(0.95))
        try check(try Data(contentsOf:file)==original,"DNG edits do not write before Done")
        model.cancelEditing()
        try check(model.edits.repairs.isEmpty && !model.isModified,"DNG Cancel restores pending repairs")
        try check(try Data(contentsOf:file)==original,"DNG Cancel leaves original file bytes untouched")
        let viewportID=model.documentID
        model.edits.repairs=[repair];model.edits.adjustments.exposure=0.5;model.commit();model.finishEditing()
        try check(model.documentID==viewportID,"Embedding DNG settings does not reset the viewport identity")
        let saved=try Data(contentsOf:file)
        try check(saved != original && !model.isModified,"DNG Done embeds edits and marks the document saved")
        try check(!FileManager.default.fileExists(atPath:WorkflowStore.sidecarURL(for:file).path),"DNG Done creates no Sidecar")
        try check(model.sourceData==saved && model.sourceDigest==WorkflowStore.digest(saved),"DNG in-memory source bytes and digest follow the embedded save")
        let recovered=try PhotoSettingsStore.read(for:file,data:saved)
        try check(recovered?.edits.repairs==[repair] && recovered?.edits.adjustments.exposure==0.5,"Embedded DNG restores repair and color parameters")
        try check(try DNGMetadataStore.identity(data:saved)==WorkflowStore.digest(original),"DNG original payload identity remains intact")
        model.edits.adjustments.exposure=2;model.commit();model.cancelEditing()
        try check(try Data(contentsOf:file)==saved && model.edits.adjustments.exposure==0.5,"DNG Cancel after Done keeps saved bytes and parameters")
        model.open(file)
        let deadline=Date().addingTimeInterval(10)
        while model.isImporting && Date()<deadline {RunLoop.current.run(until:Date().addingTimeInterval(0.02))}
        try check(!model.isImporting && model.edits.repairs==[repair] && model.edits.adjustments.exposure==0.5,"Reopening DNG automatically restores embedded settings")
        var external=saved;external.append(17);try external.write(to:file)
        model.edits.adjustments.exposure=1;model.commit()
        try check(!model.saveProject(),"A DNG changed externally is not overwritten")
        try check(try Data(contentsOf:file)==external,"Source change rejection preserves external DNG bytes")
        model.renderWork?.cancel();model.cancelEditing()
        // Legacy sidecars remain readable until the first embedded save; then
        // embedded settings take precedence without deleting the legacy file.
        let legacy=folder.appendingPathComponent("legacy.dng");try original.write(to:legacy)
        var doc=SidecarDocument(sourceSHA256:WorkflowStore.digest(original),sourceFilename:"legacy.dng",edits:.init());doc.edits.adjustments.exposure=0.75
        try WorkflowStore.writeSidecar(doc,for:legacy)
        try check(try PhotoSettingsStore.read(for:legacy,data:original)?.edits.adjustments.exposure==0.75,"Legacy DNG Sidecar can be migrated")
        doc.edits.adjustments.exposure=1.25
        let embedded=try PhotoSettingsStore.write(doc,for:legacy,expectedData:original)
        try check(try PhotoSettingsStore.read(for:legacy,data:embedded)?.edits.adjustments.exposure==1.25,"Embedded parameters take priority after DNG migration")
        try check(FileManager.default.fileExists(atPath:WorkflowStore.sidecarURL(for:legacy).path),"Migration does not delete a legacy Sidecar")
        return "File settings checks passed: \(count) assertions (DNG Done/Cancel, reopen, repair metadata, conflict protection and Sidecar migration)."
    }
}
