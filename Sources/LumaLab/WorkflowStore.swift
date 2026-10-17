import LumaDomain
import Foundation
import CryptoKit

enum SampleMode: String {
    case none, whiteBalance, pointColor, maskColor, maskLuminance
    var instruction: String {
        switch self {
        case .none: return "就绪"
        case .whiteBalance: return "点击照片中的中性灰或白色区域，设定白平衡"
        case .pointColor: return "点击照片，选取需要单独调整的颜色"
        case .maskColor: return "点击照片，为选区采样颜色"
        case .maskLuminance: return "点击照片，为选区采样亮度"
        }
    }
}

enum WorkflowStore {
    static var directoryOverride: URL?
    static var directory: URL {
        if let directoryOverride=directoryOverride {return directoryOverride}
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LumaLab", isDirectory: true)
    }
    static var workspaceURL: URL { directory.appendingPathComponent("workspace-v2.json") }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func sidecarURL(for source: URL) -> URL { source.appendingPathExtension("luma.json") }

    static func readSidecar(for source: URL, data: Data) throws -> SidecarDocument? {
        let url = sidecarURL(for: source)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let result = try JSONDecoder().decode(SidecarDocument.self, from: Data(contentsOf: url))
        guard result.version == 2 else { throw StoreError.version }
        guard result.sourceSHA256 == digest(data) else { throw StoreError.sourceChanged }
        return result
    }
    static func writeSidecar(_ document: SidecarDocument, for source: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let destination = sidecarURL(for: source)
        if let previous = try? Data(contentsOf: destination) {
            let old = try? JSONDecoder().decode(SidecarDocument.self, from: previous)
            if old?.sourceSHA256 != document.sourceSHA256 || old?.version != document.version {
                let backup = destination.appendingPathExtension("backup-" + UUID().uuidString)
                try previous.write(to: backup, options: .atomic)
            }
        }
        try encoder.encode(document).write(to: destination, options: .atomic)
    }
    static func readWorkspace() throws -> WorkspaceData {
        guard FileManager.default.fileExists(atPath: workspaceURL.path) else { return WorkspaceData() }
        return try JSONDecoder().decode(WorkspaceData.self, from: Data(contentsOf: workspaceURL))
    }
    static func writeWorkspace(_ value: WorkspaceData) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: workspaceURL, options: .atomic)
    }
    enum StoreError: LocalizedError {
        case version, sourceChanged
        var errorDescription: String? {
            switch self {
            case .version: return "旁车文件的版本暂不支持，已保留原图与描述文件。"
            case .sourceChanged: return "照片内容与旁车文件记录不一致，未自动应用旧参数。"
            }
        }
    }
}
