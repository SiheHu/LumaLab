import Foundation

extension PortableSegmentation {
    package static func unitNHWCTensor(_ rgba:Data,width:Int,height:Int) throws -> [Float] {
        guard width>0,height>0,width<=2048,height<=2048,rgba.count==width*height*4 else {throw Failure.invalidDimensions}
        let bytes=[UInt8](rgba)
        var tensor=[Float](repeating:0,count:width*height*3)
        for i in 0..<(width*height) {for c in 0..<3 {tensor[i*3+c]=Float(bytes[i*4+c])/255}}
        return tensor
    }
    package static func planarNHWCLogits(_ values:[Float],width:Int,height:Int,channels:Int) throws -> [Float] {
        guard width>0,height>0,width<=2048,height<=2048,channels>0,channels<=256,
              width*height<=67_108_864/channels,values.count==width*height*channels else {throw Failure.invalidDimensions}
        var result=[Float](repeating:0,count:values.count)
        for i in 0..<(width*height) {for c in 0..<channels {result[c*width*height+i]=values[i*channels+c]}}
        return result
    }
    package static func contains(_ p:UnitPoint2D,in polygon:[UnitPoint2D])->Bool {
        guard polygon.count>=3 else {return false}
        var odd=false,j=polygon.count-1
        for i in polygon.indices {
            let a=polygon[i],b=polygon[j]
            if (a.y>p.y) != (b.y>p.y),p.x<(b.x-a.x)*(p.y-a.y)/(b.y-a.y)+a.x {odd.toggle()}
            j=i
        }
        return odd
    }
    package static func winningLabels(logits:[Float],width:Int,height:Int,channels:Int) throws -> [UInt8] {
        _=try categoricalCoverage(logits:logits,width:width,height:height,channels:channels,selected:[])
        let plane=width*height
        return (0..<plane).map {i in
            var best=0
            for c in 1..<channels where logits[c*plane+i]>logits[best*plane+i] {best=c}
            return UInt8(best)
        }
    }
    /// Reconcile accessory-class holes only where visible pixels match nearby,
    /// semantically identified facial skin. Dark frames/opaque lenses are retained.
    /// This is a refinement of a semantic mask, never a whole-image color selector.
    package static func skinCoverage(logits:[Float],width:Int,height:Int,channels:Int=19,
                                    rgba:Data,eyePolygons:[[UnitPoint2D]],excludedPolygons:[[UnitPoint2D]]=[],
                                    faceRegions:[[UnitPoint2D]]?=nil) throws -> Data {
        guard rgba.count==width*height*4 else {throw Failure.invalidDimensions}
        let labels=try winningLabels(logits:logits,width:width,height:height,channels:channels)
        let body=channels==6,selected:Set<Int>=body ? [2,3]:[1,7,8,10,14]
        let skinLabel=body ? 3:1,accessory=body ? 5:6,raw=[UInt8](rgba)
        var result=labels.map {selected.contains(Int($0)) ? UInt8(255):0}
        let radius=max(4,min(width,height)/8)
        let exclusions=eyePolygons+excludedPolygons
        for i in labels.indices {
            let x=i%width,y=i/width,p=UnitPoint2D(x:(Double(x)+0.5)/Double(width),y:(Double(y)+0.5)/Double(height))
            let excluded=exclusions.contains {contains(p,in:$0)}
            if excluded {result[i]=0;continue}
            guard Int(labels[i])==accessory else {continue}
            if let faceRegions,!faceRegions.contains(where:{contains(p,in:$0)}) {continue}
            var sums=[Double](repeating:0,count:3),samples=0
            for dy in [-radius,-radius/2,0,radius/2,radius] {
                for dx in [-radius,-radius/2,0,radius/2,radius] {
                    let xx=x+dx,yy=y+dy
                    guard xx>=0,xx<width,yy>=0,yy<height,Int(labels[yy*width+xx])==skinLabel else {continue}
                    samples+=1
                    for c in 0..<3 {sums[c]+=Double(raw[(yy*width+xx)*4+c])/255}
                }
            }
            guard samples>=2 else {continue}
            let reference=sums.map {$0/Double(samples)},color=(0..<3).map {Double(raw[i*4+$0])/255}
            let refSum=max(0.01,reference.reduce(0,+)),sum=max(0.01,color.reduce(0,+))
            let chroma=zip(color,reference).map {abs($0/sum-$1/refSum)}.max() ?? 1
            let ratio=sum/refSum
            guard ratio>0.5,ratio<1.85,chroma<0.11 else {continue}
            let strength=min(1,(ratio-0.5)/0.15)*min(1,(1.85-ratio)/0.25)*min(1,(0.11-chroma)/0.035)
            result[i]=UInt8((255*max(0,strength)).rounded())
        }
        return Data(result)
    }
}
