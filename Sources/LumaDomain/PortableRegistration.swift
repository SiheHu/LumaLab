import Foundation
import LumaCore

package struct PhotoTransform:Equatable {
    package var matrix:[Double]
    package var inliers:Int
    package init(matrix:[Double]=[1,0,0,0,1,0,0,0,1],inliers:Int=0) {self.matrix=matrix;self.inliers=inliers}
    package func point(_ x:Double,_ y:Double)->UnitPoint2D {
        let d=matrix[6]*x+matrix[7]*y+matrix[8]
        return UnitPoint2D(x:(matrix[0]*x+matrix[1]*y+matrix[2])/d,y:(matrix[3]*x+matrix[4]*y+matrix[5])/d)
    }
    package func scaled(reference:Double,moving:Double)->PhotoTransform {
        var h=matrix
        h[0]*=moving/reference;h[1]*=moving/reference;h[2]/=reference
        h[3]*=moving/reference;h[4]*=moving/reference;h[5]/=reference
        h[6]*=moving;h[7]*=moving
        return PhotoTransform(matrix:h,inliers:inliers)
    }
}
package enum PortableRegistration {
    package struct Failure:LocalizedError {package init() {}
package var errorDescription:String? {"没有找到可靠的图像匹配；请使用有清晰纹理且相互重叠的照片。"}}
    package static func align(reference:[UInt8],rw:Int,rh:Int,moving:[UInt8],mw:Int,mh:Int,projective:Bool=false) throws -> PhotoTransform {
        guard rw>0,rh>0,mw>0,mh>0,reference.count==rw*rh*4,moving.count==mw*mh*4 else {throw Failure()}
        var matrix=[Double](repeating:0,count:9)
        let count=reference.withUnsafeBufferPointer {ref in moving.withUnsafeBufferPointer {mov in luma_register_rgba(ref.baseAddress,Int32(rw),Int32(rh),mov.baseAddress,Int32(mw),Int32(mh),projective ? 1:0,&matrix)}}
        guard count>=6 else {throw Failure()};return PhotoTransform(matrix:matrix,inliers:Int(count))
    }
}
