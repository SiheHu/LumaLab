import Foundation
import CoreGraphics
import LumaDomain

/// Recompute semantic raster per destination. The entire destination is saved only
/// after all requested semantic masks succeed, never with the source photo's raster.
enum AdaptiveMaskSync {
    static func refresh(_ edits:EditState,data:Data,fileExtension:String,generator:(AutomaticMaskKind,CGImage)throws->[AutomaticMaskResult] = {try AutomaticMaskService.shared.generate($0,image:$1)}) throws -> EditState {
        let kinds=Set(edits.masks.compactMap(\.automaticKind))
        guard !kinds.isEmpty else {return edits}
        let decoded=try PhotoIO.decode(data:data,fileExtension:fileExtension)
        let renderer=ImagePipeline(),image=try renderer.render(source:decoded.image,edits:.init(),maxDimension:2048)
        var refreshed=edits,cache=[AutomaticMaskKind:[AutomaticMaskResult]]()
        for kind in kinds {cache[kind]=try generator(kind,image)}
        for i in refreshed.masks.indices {
            guard let kind=refreshed.masks[i].automaticKind else {continue}
            let index=refreshed.masks[i].automaticIndex ?? 0
            guard let results=cache[kind],results.indices.contains(index) else {
                throw NSError(domain:"AdaptiveMaskSync",code:1,userInfo:[NSLocalizedDescriptionKey:"目标照片未识别到对应的 \(kind.title)，未保存这张照片的修改。"])
            }
            refreshed.masks[i].raster=results[index].raster
        }
        return refreshed
    }
}
