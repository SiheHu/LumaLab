import LumaDomain
import CoreImage
import Foundation

enum GeometryAutoCrop {
    static func largestRectangle(width: Int, height: Int, opaque: [Bool], aspect: Double? = nil) -> CGRect {
        guard width > 0, height > 0, opaque.count == width*height else { return .zero }
        var heights = [Int](repeating:0,count:width), best = CGRect.zero
        var bestArea = 0.0
        for y in 0..<height {
            for x in 0..<width { heights[x] = opaque[y*width+x] ? heights[x]+1 : 0 }
            var stack:[Int] = []
            for x in 0...width {
                let current = x == width ? 0 : heights[x]
                while let last = stack.last, heights[last] > current {
                    _ = stack.popLast()
                    let left = (stack.last ?? -1)+1, w = x-left, h = heights[last]
                    var candidate=CGRect(x:left,y:y-h+1,width:w,height:h)
                    if let aspect=aspect,aspect.isFinite,aspect>0 {
                        let cw=min(Double(w),Double(h)*aspect),ch=min(Double(h),Double(w)/aspect)
                        candidate=CGRect(x:Double(left)+(Double(w)-cw)/2,y:Double(y-h+1)+(Double(h)-ch)/2,width:cw,height:ch)
                    }
                    let area=candidate.width*candidate.height
                    if area>bestArea {bestArea=area;best=candidate}
                }
                if x < width {stack.append(x)}
            }
        }
        return best
    }

    static func region(in image: CIImage, context: CIContext) throws -> CropRegion {
        let bounds = image.extent
        let factor = min(1,512/max(bounds.width,bounds.height))
        let w = max(1,Int(floor(bounds.width*factor))), h = max(1,Int(floor(bounds.height*factor)))
        var alpha = image.applyingFilter("CIColorMatrix",parameters:[
            "inputRVector":CIVector(x:0,y:0,z:0,w:1),"inputGVector":CIVector(x:0,y:0,z:0,w:1),
            "inputBVector":CIVector(x:0,y:0,z:0,w:1),"inputAVector":CIVector(x:0,y:0,z:0,w:0),
            "inputBiasVector":CIVector(x:0,y:0,z:0,w:1)])
        // Expand transparent pixels before reducing resolution: even a small
        // hole must invalidate any proxy cell whose area could contain it.
        if factor < 1 {
            alpha = alpha.clampedToExtent().applyingFilter("CIMorphologyMinimum",parameters:[kCIInputRadiusKey:ceil(1.5/factor)]).cropped(to:bounds)
        }
        alpha = alpha.transformed(by:CGAffineTransform(scaleX:CGFloat(w)/bounds.width,y:CGFloat(h)/bounds.height))
        var pixels=[UInt8](repeating:0,count:w*h*4)
        pixels.withUnsafeMutableBytes { bytes in
            context.render(alpha,toBitmap:bytes.baseAddress!,rowBytes:w*4,bounds:CGRect(x:0,y:0,width:w,height:h),format:.RGBA8,colorSpace:nil)
        }
        let opaque=(0..<(w*h)).map {pixels[$0*4] == 255}
        let rectangle=largestRectangle(width:w,height:h,opaque:opaque,aspect:Double(w)/Double(h))
        guard rectangle.width >= 1,rectangle.height >= 1 else {throw ImagePipeline.PipelineError.renderFailed}
        return CropRegion(x:rectangle.minX/CGFloat(w),y:rectangle.minY/CGFloat(h),width:rectangle.width/CGFloat(w),height:rectangle.height/CGFloat(h))
    }
}
