import LumaDomain
import Foundation
import CoreImage

enum PanoramaProcessor {
    static func combine(urls:[URL],progress:@escaping(Double)->Void) throws -> StackResult {
        guard (2...8).contains(urls.count) else {throw StackProcessor.Failure.count(8)}
        var total:Int64=0
        for url in urls {total += Int64((try url.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0)}
        guard total<=256*1024*1024 else {throw StackProcessor.Failure.fileLimit}
        let linear=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
        let context=CIContext(options:[.workingColorSpace:linear,.outputColorSpace:linear,.cacheIntermediates:false])
        var transforms=[PhotoTransform](),previous:CIImage?,baseHeight:CGFloat=0,bounds=CGRect.null
        func multiply(_ a:[Double],_ b:[Double])->[Double] {
            var c=[Double](repeating:0,count:9)
            for y in 0..<3 {for x in 0..<3 {for k in 0..<3 {c[y*3+x]+=a[y*3+k]*b[k*3+x]}}}
            return c
        }
        for (index,url) in urls.enumerated() {
            let image=try PhotoIO.decode(data:Data(contentsOf:url,options:.mappedIfSafe),fileExtension:url.pathExtension).image
            try StackProcessor.validatePixelCount(width:Int(image.extent.width),height:Int(image.extent.height))
            var transform=PhotoTransform()
            if let previous {
                let pair=try ImageRegistration.align(image,to:previous,context:context,projective:true)
                transform=PhotoTransform(matrix:multiply(transforms.last!.matrix,pair.matrix),inliers:pair.inliers)
            } else {baseHeight=image.extent.height}
            let corners=[(0.0,0.0),(Double(image.extent.width),0.0),(0.0,Double(image.extent.height)),(Double(image.extent.width),Double(image.extent.height))]
            let denominators=corners.map {transform.matrix[6]*$0.0+transform.matrix[7]*$0.1+transform.matrix[8]}
            guard denominators.allSatisfy({$0>0.01}) || denominators.allSatisfy({$0 < -0.01}) else {throw PortableRegistration.Failure()}
            let warped=ImageRegistration.warped(CIImage(color:.white).cropped(to:image.extent),transform:transform,referenceHeight:baseHeight)
            let extent=warped.extent
            guard extent.width.isFinite,extent.height.isFinite,extent.width>0,extent.height>0 else {throw PortableRegistration.Failure()}
            bounds=bounds.union(extent).integral
            guard bounds.width<=100000,bounds.height<=100000,bounds.width*bounds.height<=100000000 else {throw StackProcessor.Failure.pixelLimit}
            transforms.append(transform);previous=image
            progress(0.25*Double(index+1)/Double(urls.count))
        }
        previous=nil
        guard let weightKernel=CIColorKernel(source:"""
        kernel vec4 feather(vec2 size,float radius) {
            vec2 p=destCoord();float d=min(min(p.x,p.y),min(size.x-p.x,size.y-p.y));
            float w=clamp(d/radius,0.001,1.0);return vec4(vec3(w),1.0);
        }
        """),let blendKernel=CIColorKernel(source:"""
        kernel vec4 mosaic(__sample s,__sample d,__sample sw,__sample dw) {
            float a=sw.r*s.a,b=dw.r*d.a;
            vec3 rgb=(unpremultiply(s).rgb*a+unpremultiply(d).rgb*b)/max(a+b,0.000001);
            return premultiply(vec4(rgb,max(s.a,d.a)));
        }
        """),let sumKernel=CIColorKernel(source:"""
        kernel vec4 weights(__sample s,__sample d,__sample sw) {return vec4(vec3(d.r+sw.r*s.a),1.0);}
        """) else {throw StackProcessor.Failure.rendering}
        var composite=CIImage(color:.clear).cropped(to:bounds),weights=CIImage(color:.black).cropped(to:bounds)
        for (index,url) in urls.enumerated() {
            try autoreleasepool {
                let image=try PhotoIO.decode(data:Data(contentsOf:url,options:.mappedIfSafe),fileExtension:url.pathExtension).image
                let source=ImageRegistration.warped(image,transform:transforms[index],referenceHeight:baseHeight).cropped(to:bounds)
                guard let local=weightKernel.apply(extent:image.extent,arguments:[CIVector(x:image.extent.width,y:image.extent.height),max(8,min(image.extent.width,image.extent.height)*0.12)]) else {throw StackProcessor.Failure.rendering}
                let sw=ImageRegistration.warped(local,transform:transforms[index],referenceHeight:baseHeight).cropped(to:bounds)
                guard let merged=blendKernel.apply(extent:bounds,arguments:[source,composite,sw,weights]),let sum=sumKernel.apply(extent:bounds,arguments:[source,weights,sw]),
                      let result=context.createCGImage(merged,from:bounds,format:.RGBAh,colorSpace:linear),let cachedWeights=context.createCGImage(sum,from:bounds,format:.RGBAh,colorSpace:linear) else {throw StackProcessor.Failure.rendering}
                let shift=CGAffineTransform(translationX:bounds.minX,y:bounds.minY)
                composite=CIImage(cgImage:result).transformed(by:shift);weights=CIImage(cgImage:cachedWeights).transformed(by:shift)
            }
            context.clearCaches();progress(0.25+0.75*Double(index+1)/Double(urls.count))
        }
        let normalized=composite.transformed(by:CGAffineTransform(translationX:-bounds.minX,y:-bounds.minY))
        return StackResult(image:normalized,report:"Panorama · \(urls.count) 张 · \(Int(bounds.width)) × \(Int(bounds.height)) · Projective Registration / Feather Blend。透明边缘可在裁剪栏处理。")
    }
}
