import LumaDomain
import Foundation
import AppKit

enum RecoveryStore {
    static var directory:URL {WorkflowStore.directory.appendingPathComponent("Recovery",isDirectory:true)}
    static var manifest:URL {directory.appendingPathComponent("pending.json")}
    static func write(_ record:RecoveryRecord,data:Data) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let asset=directory.appendingPathComponent(record.dataFilename)
        if !FileManager.default.fileExists(atPath:asset.path) {try data.write(to:asset,options:.atomic)}
        try JSONEncoder().encode(record).write(to:manifest,options:.atomic)
        for url in (try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? [] where url.lastPathComponent != record.dataFilename && url.lastPathComponent != "pending.json" {try? FileManager.default.removeItem(at:url)}
    }
    static func read() throws -> (RecoveryRecord,Data)? {
        guard FileManager.default.fileExists(atPath:manifest.path) else {return nil}
        let record=try JSONDecoder().decode(RecoveryRecord.self,from:Data(contentsOf:manifest))
        guard record.dataFilename==URL(fileURLWithPath:record.dataFilename).lastPathComponent else {throw WorkflowStore.StoreError.sourceChanged}
        let data=try Data(contentsOf:directory.appendingPathComponent(record.dataFilename))
        guard WorkflowStore.digest(data)==record.digest else {throw WorkflowStore.StoreError.sourceChanged}
        return (record,data)
    }
    static func clear() {try? FileManager.default.removeItem(at:directory)}
}
@MainActor extension EditorModel {
    func scheduleRecovery() {
        guard recoveryEnabled,!recoveryPromptActive else {return}
        if !recoveryOffered {offerRecovery()}
        guard recoveryOffered,!recoveryPromptActive else {return}
        recoveryWork?.cancel()
        guard isModified else {ioQueue.async {RecoveryStore.clear()};return}
        guard !sourceData.isEmpty,!isImporting else {return}
        let record=RecoveryRecord(sourceName:sourceName,dataFilename:sourceDigest+".source",digest:sourceDigest,sourcePath:sourceURL?.path,projectPath:projectURL?.path,edits:edits,savedState:savedState,snapshots:snapshots,virtualCopies:virtualCopies,history:history,historyIndex:historyIndex,structureDirty:documentStructureDirty,newDocument:newDocumentNeedsSave)
        let data=sourceData
        let job=DispatchWorkItem {do {try RecoveryStore.write(record,data:data)} catch {DispatchQueue.main.async {[weak self] in self?.status="恢复记录写入失败，当前编辑仍保留在内存中"}}}
        recoveryWork=job;ioQueue.asyncAfter(deadline:.now()+1,execute:job)
    }
    func clearRecovery() {
        guard recoveryEnabled else {return}
        recoveryWork?.cancel();ioQueue.sync {RecoveryStore.clear()}
    }
    func offerRecovery() {
        guard recoveryEnabled,!recoveryOffered,!recoveryPromptActive else {return}
        do {
            guard let (record,data)=try RecoveryStore.read() else {recoveryOffered=true;return}
            guard let window=editorWindow else {return}
            recoveryPromptActive=true;objectWillChange.send()
            let alert=NSAlert();alert.messageText=L("发现未保存的编辑");alert.informativeText=record.sourceName
            alert.addButton(withTitle:L("恢复编辑"));alert.addButton(withTitle:L("丢弃恢复记录"))
            alert.beginSheetModal(for:window) { [weak self] response in
                guard let self else {return}
                self.recoveryPromptActive=false;self.objectWillChange.send()
                if response == .alertSecondButtonReturn {
                    self.recoveryOffered=true;self.clearRecovery();self.recoveryCompletion?();return
                }
                guard response == .alertFirstButtonReturn else {return}
                self.recoveryOffered=true
                do {
                    let decoded=try PhotoIO.decode(data:data,fileExtension:URL(fileURLWithPath:record.sourceName).pathExtension)
                    self.recoveryEnabled=false
                    self.adopt(decoded:decoded,data:data,name:record.sourceName,state:record.edits)
                    self.recoveryEnabled=true
                    self.savedState=record.savedState;self.snapshots=record.snapshots;self.virtualCopies=record.virtualCopies
                    self.history=record.history.isEmpty ? [record.edits]:record.history;self.historyIndex=min(self.history.count-1,max(0,record.historyIndex))
                    self.documentStructureDirty=record.structureDirty;self.newDocumentNeedsSave=record.newDocument
                    if let path=record.sourcePath,let current=try? Data(contentsOf:URL(fileURLWithPath:path)),WorkflowStore.digest(current)==record.digest {self.sourceURL=URL(fileURLWithPath:path)}
                    if let path=record.projectPath {self.projectURL=URL(fileURLWithPath:path)}
                    self.requestRender();self.status="已恢复未保存编辑，按 ⌘S 保存";self.recoveryCompletion?()
                } catch {self.errorMessage="恢复记录无法读取，记录已保留：\(error.localizedDescription)"}
            }
        } catch {
            recoveryEnabled=false
            errorMessage="恢复记录无法读取，记录已保留：\(error.localizedDescription)"
        }
    }
}
