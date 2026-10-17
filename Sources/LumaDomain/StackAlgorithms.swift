import Foundation
import LumaCore

package enum PortableStack {
    package static func median(_ values:[Float])->Float {
        guard !values.isEmpty else {return 0};let s=values.sorted(),i=s.count/2
        return s.count%2==0 ? (s[i-1]+s[i])/2:s[i]
    }
    package static func sigmaClippedMean(_ values:[Float],sigma:Float=3)->Float {
        values.withUnsafeBufferPointer {luma_sigma_mean($0.baseAddress,Int32(values.count),sigma)}
    }
    package static func focusScores(_ values:[Float],width:Int,height:Int)->[Float] {
        guard width>0,height>0,values.count==width*height*4 else {return []}
        var luma=[Float](repeating:0,count:width*height),energy=luma,result=luma
        for i in luma.indices {luma[i]=values[i*4]*0.2126+values[i*4+1]*0.7152+values[i*4+2]*0.0722}
        for y in 0..<height {for x in 0..<width {
            let i=y*width+x,left=y*width+max(0,x-1),right=y*width+min(width-1,x+1),up=max(0,y-1)*width+x,down=min(height-1,y+1)*width+x
            energy[i]=abs(luma[left]+luma[right]+luma[up]+luma[down]-4*luma[i])
        }}
        // Separable 5x5 local energy prevents selecting isolated sharp pixels.
        var horizontal=luma
        for y in 0..<height {for x in 0..<width {var sum:Float=0;for dx in -2...2 {sum+=energy[y*width+min(width-1,max(0,x+dx))]};horizontal[y*width+x]=sum/5}}
        for y in 0..<height {for x in 0..<width {var sum:Float=0;for dy in -2...2 {sum+=horizontal[min(height-1,max(0,y+dy))*width+x]};let value=sum/5+0.0001;result[y*width+x]=value*value*value*value}}
        return result
    }
    package static func isGhost(samples:[[Float]],gains:[Float],reference:Int,threshold:Float)->Bool {
        guard samples.indices.contains(reference),gains.count==samples.count else {return false}
        let r=samples[reference]
        guard r.count>=3 else {return false}
        for (i,v) in samples.enumerated() where v.count>=3 && i != reference {
            // Ignore clipped samples, whose exposure-normalized values are unreliable.
            guard v.prefix(3).max()!<0.98,r.prefix(3).max()!<0.98 else {continue}
            let d=(0..<3).map {abs(v[$0]*gains[i]-r[$0]*gains[reference])}.max() ?? 0
            let light=max(0.03,(r[0]+r[1]+r[2])*gains[reference]/3)
            if d>max(0.01,threshold*light) {return true}
        }
        return false
    }
}
