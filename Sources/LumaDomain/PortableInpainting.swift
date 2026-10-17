import Foundation
import CAutomaticMask

/// Portable, local content reconstruction with the fixed 512px LaMa ONNX model.
/// Inputs and outputs are tightly packed, row-major top-left sRGB RGBA8; masks
/// are matching gray8 coverage. The caller supplies a context ROI from the
/// full-resolution photograph. Pixels with mask > 0 receive full prediction;
/// the caller applies feather/opacity once. Mask-zero pixels and alpha are exact.
public final class PortableInpaintingProcessor {
    public static let modelID = "lama-carve-fp32-1faef530-v1"
    public static let modelDimension = 512
    public static let maximumPixels = 20_000_000
    private let handle: UnsafeMutableRawPointer
    private let lock = NSLock()

    public enum Failure: LocalizedError {
        case invalidDimensions, unavailable(String), inference(String)
        public var errorDescription: String? {
            switch self {
            case .invalidDimensions: return "Invalid inpainting image or mask dimensions."
            case .unavailable(let text), .inference(let text): return text
            }
        }
    }
    public init(runtimeURL: URL, modelURL: URL) throws {
        var error = [CChar](repeating:0,count:4096)
        guard let created = luma_onnx_create(runtimeURL.path,modelURL.path,&error,error.count) else { throw Failure.unavailable(String(cString:error)) }
        var shape = [Int64](repeating:0,count:4)
        guard luma_onnx_input_shape(created,&shape,&error,error.count) != 0,
              (shape[0] == 1 || shape[0] == -1),shape[1] == 3,shape[2] == 512,shape[3] == 512 else {
            luma_onnx_destroy(created)
            throw Failure.unavailable("Incompatible LaMa model input; expected Float32 1×3×512×512.")
        }
        self.handle = created
    }
    deinit { luma_onnx_destroy(handle) }

    public func process(rgba: Data, mask: Data, width: Int, height: Int) throws -> Data {
        guard Self.valid(width:width,height:height),rgba.count == width*height*4,mask.count == width*height else { throw Failure.invalidDimensions }
        guard mask.contains(where:{$0>0}) else { return rgba }
        lock.lock(); defer { lock.unlock() }
        let prepared = try PortableInpainting.prepare(rgba:rgba,mask:mask,width:width,height:height)
        var input = prepared.image, selection = prepared.mask
        var inputShape: [Int64] = [1,3,512,512], maskShape: [Int64] = [1,1,512,512]
        var output: UnsafeMutablePointer<Float>?, outputShape = [Int64](repeating:0,count:4), count = 0
        var error = [CChar](repeating:0,count:4096)
        guard luma_onnx_run_masked(handle,&input,&inputShape,&selection,&maskShape,&output,&outputShape,&count,&error,error.count) != 0,let output else { throw Failure.inference(String(cString:error)) }
        defer { luma_onnx_free(output) }
        guard outputShape == [1,3,512,512],count == 3*512*512 else { throw Failure.inference("Unexpected LaMa output dimensions.") }
        let values = Array(UnsafeBufferPointer(start:output,count:count))
        guard values.allSatisfy({$0.isFinite}) else { throw Failure.inference("LaMa returned nonfinite pixels.") }
        return try PortableInpainting.composite(output:values,onto:rgba,mask:mask,width:width,height:height,layout:prepared.layout)
    }
    fileprivate static func valid(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= 16384 && height <= 16384 && width <= maximumPixels/height
    }
}

/// Pre/postprocessing is shared with future Windows builds and independently
/// testable without a model, display server, Core Image, or graphics framework.
public enum PortableInpainting {
    public struct Layout: Equatable {
        public let width: Int
        public let height: Int
        public let offsetX: Int
        public let offsetY: Int
    }
    public struct Prepared {
        public let image: [Float]
        public let mask: [Float]
        public let layout: Layout
    }
    /// Convert premultiplied decoder bytes to the model's straight sRGB input.
    /// Alpha-zero RGB is cleared; opaque bytes are retained without arithmetic.
    public static func straightRGBA(fromPremultiplied input: Data) -> Data {
        guard input.count % 4 == 0 else { return input }
        var bytes = [UInt8](input)
        for index in stride(from:0,to:bytes.count,by:4) {
            let alpha = Int(bytes[index+3])
            if alpha == 255 { continue }
            for c in 0..<3 {
                bytes[index+c] = alpha == 0 ? 0 : UInt8(min(255,(Int(bytes[index+c])*255+alpha/2)/alpha))
            }
        }
        return Data(bytes)
    }
    /// Return straight prediction to a premultiplied renderer. Alpha is exact.
    public static func premultipliedRGBA(fromStraight input: Data) -> Data {
        guard input.count % 4 == 0 else { return input }
        var bytes = [UInt8](input)
        for index in stride(from:0,to:bytes.count,by:4) {
            let alpha = Int(bytes[index+3])
            if alpha == 255 { continue }
            for c in 0..<3 { bytes[index+c] = UInt8((Int(bytes[index+c])*alpha+127)/255) }
        }
        return Data(bytes)
    }
    public static func prepare(rgba: Data, mask: Data, width: Int, height: Int) throws -> Prepared {
        guard PortableInpaintingProcessor.valid(width:width,height:height),rgba.count == width*height*4,mask.count == width*height else { throw PortableInpaintingProcessor.Failure.invalidDimensions }
        let size = PortableInpaintingProcessor.modelDimension
        let scale = Double(size)/Double(max(width,height))
        let sw = min(size,max(1,Int((Double(width)*scale).rounded())))
        let sh = min(size,max(1,Int((Double(height)*scale).rounded())))
        let ox = (size-sw)/2, oy = (size-sh)/2
        let layout = Layout(width:sw,height:sh,offsetX:ox,offsetY:oy)
        let source = [UInt8](rgba), selected = [UInt8](mask), plane = size*size
        var rgb = [Float](repeating:0,count:3*plane), matte = [Float](repeating:0,count:plane)
        for y in 0..<size {
            // Reflect image context into padding; coverage is mirrored consistently below.
            let ly = reflect(y-oy,length:sh)
            let py = min(Double(height-1),max(0,(Double(ly)+0.5)/Double(sh)*Double(height)-0.5))
            let iy = Int(py), jy = min(height-1,iy+1), fy = Float(py-Double(iy))
            for x in 0..<size {
                let lx = reflect(x-ox,length:sw)
                let px = min(Double(width-1),max(0,(Double(lx)+0.5)/Double(sw)*Double(width)-0.5))
                let ix = Int(px), jx = min(width-1,ix+1), fx = Float(px-Double(ix))
                for c in 0..<3 {
                    let a = Float(source[(iy*width+ix)*4+c])*(1-fx)+Float(source[(iy*width+jx)*4+c])*fx
                    let b = Float(source[(jy*width+ix)*4+c])*(1-fx)+Float(source[(jy*width+jx)*4+c])*fx
                    rgb[c*plane+y*size+x] = (a*(1-fy)+b*fy)/255
                }
            }
        }
        // Max reduction over source footprints keeps narrow lines selected when
        // a high-resolution ROI shrinks; plain bilinear/nearest can miss them.
        for y in 0..<sh {
            let y0 = max(0,min(height-1,Int(floor(Double(y)/Double(sh)*Double(height)-0.5))))
            let y1 = min(height,max(y0+1,Int(ceil(Double(y+1)/Double(sh)*Double(height)+0.5))))
            for x in 0..<sw {
                let x0 = max(0,min(width-1,Int(floor(Double(x)/Double(sw)*Double(width)-0.5))))
                let x1 = min(width,max(x0+1,Int(ceil(Double(x+1)/Double(sw)*Double(width)+0.5))))
                var covered = false
                for sy in y0..<y1 {
                    for sx in x0..<x1 where selected[sy*width+sx]>0 { covered = true; break }
                    if covered { break }
                }
                if covered { matte[(y+oy)*size+x+ox] = 1 }
            }
        }
        // Reflection must carry the removal mask too: otherwise padding can
        // present a mirrored copy of the very object as known clean context.
        for y in 0..<size {for x in 0..<size where y<oy || y>=oy+sh || x<ox || x>=ox+sw {
            matte[y*size+x]=matte[(reflect(y-oy,length:sh)+oy)*size+reflect(x-ox,length:sw)+ox]
        }}
        return Prepared(image:rgb,mask:matte,layout:layout)
    }
    public static func composite(output: [Float], onto rgba: Data, mask: Data, width: Int, height: Int, layout: Layout, applyCoverage: Bool = false) throws -> Data {
        let size = PortableInpaintingProcessor.modelDimension, plane = size*size
        guard PortableInpaintingProcessor.valid(width:width,height:height),rgba.count == width*height*4,mask.count == width*height,
              output.count == plane*3,layout.width > 0,layout.height > 0,layout.offsetX >= 0,layout.offsetY >= 0,
              layout.offsetX+layout.width <= size,layout.offsetY+layout.height <= size else { throw PortableInpaintingProcessor.Failure.invalidDimensions }
        guard output.allSatisfy({$0.isFinite}) else { throw PortableInpaintingProcessor.Failure.inference("Nonfinite inpainting output.") }
        var result = [UInt8](rgba);let selected = [UInt8](mask)
        for y in 0..<height {
            let py = min(Double(layout.offsetY+layout.height-1),max(Double(layout.offsetY),(Double(y)+0.5)/Double(height)*Double(layout.height)-0.5+Double(layout.offsetY)))
            let iy = Int(py), jy = min(layout.offsetY+layout.height-1,iy+1), fy = Float(py-Double(iy))
            for x in 0..<width where selected[y*width+x]>0 {
                let px = min(Double(layout.offsetX+layout.width-1),max(Double(layout.offsetX),(Double(x)+0.5)/Double(width)*Double(layout.width)-0.5+Double(layout.offsetX)))
                let ix = Int(px), jx = min(layout.offsetX+layout.width-1,ix+1), fx = Float(px-Double(ix))
                let alpha: Float = applyCoverage ? Float(selected[y*width+x])/255 : 1
                let i = (y*width+x)*4
                for c in 0..<3 {
                    // This LaMa export returns RGB values in [0,255], not [0,1].
                    let a = output[c*plane+iy*size+ix]*(1-fx)+output[c*plane+iy*size+jx]*fx
                    let b = output[c*plane+jy*size+ix]*(1-fx)+output[c*plane+jy*size+jx]*fx
                    let fill = min(255,max(0,a*(1-fy)+b*fy))
                    guard fill.isFinite else { throw PortableInpaintingProcessor.Failure.inference("Nonfinite inpainting pixel.") }
                    result[i+c] = UInt8((Float(result[i+c])*(1-alpha)+fill*alpha).rounded())
                }
                // Original alpha is retained, including partially transparent PNGs.
            }
        }
        return Data(result)
    }
    private static func reflect(_ coordinate: Int, length: Int) -> Int {
        guard length > 1 else { return 0 }
        let period = 2*length, wrapped = ((coordinate%period)+period)%period
        return wrapped < length ? wrapped : period-1-wrapped
    }
}
