import Foundation

/// Platform-neutral preprocessing, class selection, and crop reprojection for
/// portable ONNX segmentation. Image decoding/detection stays in platform adapters.
public enum PortableSegmentation {
    public enum Failure: Error { case invalidDimensions, invalidTensor }
    public static func faceLabels(for kind: AutomaticMaskKind) -> Set<Int> {
        switch kind {
        case .face: return Set([1,2,3,4,5,6,7,8,10,11,12,13])
        case .skin: return Set([1,7,8,10,14])
        case .hair: return Set([17])
        case .eyes: return Set([4,5])
        case .glasses: return Set([6])
        case .lips: return Set([12,13])
        default: return []
        }
    }
    public static func normalizedRGBATensor(_ rgba: Data, width: Int, height: Int) throws -> [Float] {
        guard width > 0 && height > 0 && width <= 2048 && height <= 2048 && rgba.count == width*height*4 else { throw Failure.invalidDimensions }
        let pixels = [UInt8](rgba), plane = width*height
        let mean:[Float] = [0.485,0.456,0.406], deviation:[Float] = [0.229,0.224,0.225]
        var tensor = [Float](repeating:0,count:plane*3)
        for p in 0..<plane { for c in 0..<3 { tensor[c*plane+p] = (Float(pixels[p*4+c])/255-mean[c])/deviation[c] } }
        return tensor
    }
    public static func categoricalCoverage(logits: [Float], width: Int, height: Int, channels: Int, selected: Set<Int>) throws -> Data {
        guard width > 0 && height > 0 && width <= 2048 && height <= 2048 && channels > 0 && channels <= 256,
              width*height <= 67_108_864/channels, logits.count == width*height*channels else { throw Failure.invalidDimensions }
        guard logits.allSatisfy({ $0.isFinite }) else { throw Failure.invalidTensor }
        let plane = width*height
        var result = [UInt8](repeating:0,count:plane)
        for pixel in 0..<plane {
            var maximum = -Float.greatestFiniteMagnitude, winner = 0
            for label in 0..<channels {
                let value = logits[label*plane+pixel]
                if value > maximum { maximum = value; winner = label }
            }
            // Logit confidence is classification uncertainty, not opacity. Fully
            // select the winning semantic class so interior skin/hair receives a
            // uniform adjustment. Bilinear reprojection smooths the boundary.
            if selected.contains(winner) { result[pixel] = 255 }
        }
        return Data(result)
    }
    /// Semantic eyes are spatially constrained by actual eye openings when landmarks exist.
    /// This also recovers eye pixels misclassified as skin or transparent glasses.
    package static func eyeCoverage(logits:[Float],width:Int,height:Int,polygons:[[UnitPoint2D]]) throws -> Data {
        let labels=try winningLabels(logits:logits,width:width,height:height,channels:19)
        guard !polygons.isEmpty else {return Data(labels.map {[4,5].contains(Int($0)) ? 255:0})}
        return Data(labels.enumerated().map { i,label in
            let point=UnitPoint2D(x:(Double(i%width)+0.5)/Double(width),y:(Double(i/width)+0.5)/Double(height))
            return [1,4,5,6].contains(Int(label)) && polygons.contains(where:{contains(point,in:$0)}) ? 255:0
        })
    }
    public static func place(_ input: Data, inputWidth: Int, inputHeight: Int, x: Double, y: Double,
                             cropWidth: Double, cropHeight: Double, width: Int, height: Int) throws -> Data {
        guard inputWidth > 0 && inputHeight > 0 && inputWidth <= 4096 && inputHeight <= 4096 && input.count == inputWidth*inputHeight,
              width > 0 && height > 0 && width <= 4096 && height <= 4096,
              [x,y,cropWidth,cropHeight].allSatisfy({$0.isFinite}), cropWidth > 0, cropHeight > 0,
              x >= 0, y >= 0, x+cropWidth <= 1.000001, y+cropHeight <= 1.000001 else { throw Failure.invalidDimensions }
        let data = [UInt8](input)
        var output = [UInt8](repeating:0,count:width*height)
        let x0 = max(0,Int(floor(x*Double(width)))), y0 = max(0,Int(floor(y*Double(height))))
        let x1 = min(width,Int(ceil((x+cropWidth)*Double(width)))), y1 = min(height,Int(ceil((y+cropHeight)*Double(height))))
        guard x1 > x0, y1 > y0 else { return Data(output) }
        for py in y0..<y1 {
            let v = min(Double(inputHeight-1),max(0,((Double(py)+0.5)/Double(height)-y)/cropHeight*Double(inputHeight)-0.5))
            let iy = Int(v), jy = min(inputHeight-1,iy+1), fy = v-Double(iy)
            for px in x0..<x1 {
                let u = min(Double(inputWidth-1),max(0,((Double(px)+0.5)/Double(width)-x)/cropWidth*Double(inputWidth)-0.5))
                let ix = Int(u), jx = min(inputWidth-1,ix+1), fx = u-Double(ix)
                let a = Double(data[iy*inputWidth+ix])*(1-fx)+Double(data[iy*inputWidth+jx])*fx
                let b = Double(data[jy*inputWidth+ix])*(1-fx)+Double(data[jy*inputWidth+jx])*fx
                output[py*width+px] = UInt8((a*(1-fy)+b*fy).rounded())
            }
        }
        return Data(output)
    }
}
