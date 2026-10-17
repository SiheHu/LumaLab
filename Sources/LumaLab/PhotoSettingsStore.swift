import LumaDomain
import Foundation

/// DNG uses a private namespace in standard embedded XMP; other formats retain
/// the existing sidecar format. Adobe settings and native RAW pixels are preserved.
enum PhotoSettingsStore {
    static func read(for url:URL,data:Data) throws -> SidecarDocument? {
        if url.pathExtension.lowercased()=="dng",var embedded=try DNGMetadataStore.read(data:data) {
            embedded.sourceSHA256=WorkflowStore.digest(data)
            return embedded
        }
        return try WorkflowStore.readSidecar(for:url,data:data)
    }
    @discardableResult
    static func write(_ document:SidecarDocument,for url:URL,expectedData:Data) throws -> Data {
        let access=url.startAccessingSecurityScopedResource();defer {if access {url.stopAccessingSecurityScopedResource()}}
        guard try Data(contentsOf:url)==expectedData,document.sourceSHA256==WorkflowStore.digest(expectedData) else {throw WorkflowStore.StoreError.sourceChanged}
        if url.pathExtension.lowercased() != "dng" {try WorkflowStore.writeSidecar(document,for:url);return expectedData}
        let output=try DNGMetadataStore.embed(document:document,in:expectedData)
        let before=try PhotoIO.decode(data:expectedData,fileExtension:"dng")
        let after=try PhotoIO.decode(data:output,fileExtension:"dng")
        guard before.image.extent==after.image.extent else {throw PhotoIO.Failure.rawPreviewOnly}
        guard try Data(contentsOf:url)==expectedData else {throw WorkflowStore.StoreError.sourceChanged}
        try output.write(to:url,options:.atomic)
        return output
    }
}
