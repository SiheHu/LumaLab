import Foundation
import LumaDomain

/// macOS resource-location adapter. All pixel processing and ONNX calls live in
/// LumaDomain and the portable C ABI; Windows can provide its own paths.
final class ContentRepairService {
    static let shared = ContentRepairService()
    private let lock = NSLock()
    private var processor: PortableInpaintingProcessor?
    func process(rgba: Data, mask: Data, width: Int, height: Int) throws -> Data {
        let worker = try cachedProcessor()
        return try worker.process(rgba:rgba,mask:mask,width:width,height:height)
    }
    private func cachedProcessor() throws -> PortableInpaintingProcessor {
        lock.lock(); defer { lock.unlock() }
        if let processor { return processor }
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let modelCandidates = [Bundle.main.resourceURL?.appendingPathComponent("AutoMasks/lama-fp32.onnx"),root.appendingPathComponent("Resources/AutoMasks/lama-fp32.onnx")].compactMap{$0}
        let runtimeCandidates = [Bundle.main.privateFrameworksURL?.appendingPathComponent("libonnxruntime.1.20.1.dylib"),root.appendingPathComponent("Vendor/ONNXRuntime/lib/libonnxruntime.1.20.1.dylib")].compactMap{$0}
        guard let model = modelCandidates.first(where:{FileManager.default.fileExists(atPath:$0.path)}),
              let runtime = runtimeCandidates.first(where:{FileManager.default.fileExists(atPath:$0.path)}) else {
            throw PortableInpaintingProcessor.Failure.unavailable("此安装包缺少内容重建模型或本地模型运行库。")
        }
        let created = try PortableInpaintingProcessor(runtimeURL:runtime,modelURL:model)
        self.processor = created
        return created
    }
}
