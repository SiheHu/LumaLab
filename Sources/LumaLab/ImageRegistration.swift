import LumaDomain
import CoreImage
import Foundation

enum ImageRegistration {
    static let srgb=CGColorSpace(name:CGColorSpace.sRGB)!
    static func proxy(_ image:CIImage,context:CIContext) throws -> (pixels:[UInt8],width:Int,height:Int,scale:Double) {
        let normalized=image.transformed(by:CGAffineTransform(translationX:-image.extent.minX,y:-image.extent.minY))
        let scale=min(1,1024/max(normalized.extent.width,normalized.extent.height))
        let small=normalized.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        guard let cg=context.createCGImage(small,from:small.extent.integral,format:.RGBA8,colorSpace:srgb),let data=cg.dataProvider?.data else {throw StackProcessor.Failure.rendering}
        let raw=[UInt8](data as Data);var pixels=[UInt8](repeating:0,count:cg.width*cg.height*4)
        for y in 0..<cg.height {pixels.replaceSubrange(y*cg.width*4..<(y+1)*cg.width*4,with:raw[y*cg.bytesPerRow..<y*cg.bytesPerRow+cg.width*4])}
        return (pixels,cg.width,cg.height,scale)
    }
    static func align(_ moving:CIImage,to reference:CIImage,context:CIContext,projective:Bool=false) throws -> PhotoTransform {
        let a=try proxy(reference,context:context),b=try proxy(moving,context:context)
        return try PortableRegistration.align(reference:a.pixels,rw:a.width,rh:a.height,moving:b.pixels,mw:b.width,mh:b.height,projective:projective).scaled(reference:a.scale,moving:b.scale)
    }
    static func affine(_ transform:PhotoTransform,movingHeight:CGFloat,referenceHeight:CGFloat)->CGAffineTransform {
        func point(_ x:Double,_ y:Double)->CGPoint {let p=transform.point(x,Double(movingHeight)-y);return CGPoint(x:p.x,y:Double(referenceHeight)-p.y)}
        let p=point(0,0),x=point(1,0),y=point(0,1)
        return CGAffineTransform(a:x.x-p.x,b:x.y-p.y,c:y.x-p.x,d:y.y-p.y,tx:p.x,ty:p.y)
    }
    static func warped(_ image:CIImage,transform:PhotoTransform,referenceHeight:CGFloat)->CIImage {
        let w=image.extent.width,h=image.extent.height
        func vector(_ x:Double,_ y:Double)->CIVector {let p=transform.point(x,y);return CIVector(x:p.x,y:Double(referenceHeight)-p.y)}
        return image.applyingFilter("CIPerspectiveTransform",parameters:["inputTopLeft":vector(0,0),"inputTopRight":vector(w,0),"inputBottomLeft":vector(0,h),"inputBottomRight":vector(w,h)])
    }
}
