import Foundation

/// Platform-neutral Healing numerical routines; no image framework or GPU types.
package enum PortableHealing {
    /// Bounded outward transition for full-core content removal. A large Brush
    /// must not erase a second wide band of scene structure just to soften its
    /// seam. The same pixel-space width drives the native cursor and renderer.
    package static func inpaintingFeatherWidth(radius:Double,imageShortDimension:Double,feather:Double)->Double {
        min(1,max(0,feather))*min(radius,max(2,imageShortDimension*0.02))
    }
    /// Independent minimum-curvature correction. Harmonic interpolation gives
    /// a fast initial field; Conjugate Gradient then solves Delta²u=0 inside
    /// the selected domain with its surrounding values held fixed. The 13-point
    /// operator is the standard composition of two five-point Laplacians.
    /// Unlike a harmonic field this can continue curved illumination across a
    /// repair while matching its boundary slope. This is not an Adobe port.
    package static func solveBiharmonic(diff:[Float],unknown:[Bool],width w:Int,height h:Int)->[Float] {
        guard w>=5,h>=5,diff.count==w*h*4,unknown.count==w*h else {return diff}
        var result=solve(diff:diff,unknown:unknown,width:w,height:h)
        let indices=(0..<w*h).filter {unknown[$0] && $0%w>=2 && $0%w<w-2 && $0/w>=2 && $0/w<h-2}
        guard !indices.isEmpty else {return result}
        @inline(__always) func laplacianSquared(_ values:[Float],_ i:Int,_ stride:Int,_ c:Int)->Float {
            let center=values[i*stride+c]
            let near=values[(i-1)*stride+c]+values[(i+1)*stride+c]+values[(i-w)*stride+c]+values[(i+w)*stride+c]
            let diagonal=values[(i-w-1)*stride+c]+values[(i-w+1)*stride+c]+values[(i+w-1)*stride+c]+values[(i+w+1)*stride+c]
            let far=values[(i-2)*stride+c]+values[(i+2)*stride+c]+values[(i-2*w)*stride+c]+values[(i+2*w)*stride+c]
            return 20*center-8*near+2*diagonal+far
        }
        var residual=[Float](repeating:0,count:w*h),direction=residual,product=residual
        for c in 0..<3 {
            var squared=0.0
            for i in indices {let r = -laplacianSquared(result,i,4,c);residual[i]=r;direction[i]=r;squared+=Double(r)*Double(r)}
            let initial=squared
            guard initial>1e-16 else {continue}
            for _ in 0..<160 {
                var denominator=0.0
                for i in indices {product[i]=laplacianSquared(direction,i,1,0);denominator+=Double(direction[i])*Double(product[i])}
                guard denominator>1e-24 else {break}
                let alpha=Float(squared/denominator)
                var next=0.0
                for i in indices {result[i*4+c]+=alpha*direction[i];residual[i]-=alpha*product[i];next+=Double(residual[i])*Double(residual[i])}
                if next<max(1e-16,initial*1e-9) {break}
                let beta=Float(next/squared)
                for i in indices {direction[i]=residual[i]+beta*direction[i]}
                squared=next
            }
        }
        return result
    }
    package static func solve(diff:[Float],unknown:[Bool],width w:Int,height h:Int)->[Float] {
        var result=diff
        if w>12 && h>12 {
            let cw=(w+1)/2,ch=(h+1)/2
            var coarse=[Float](repeating:0,count:cw*ch*4),flags=[Bool](repeating:false,count:cw*ch)
            for y in 0..<ch {for x in 0..<cw {
                let i=min(h-1,y*2)*w+min(w-1,x*2),j=y*cw+x
                flags[j]=unknown[i]
                for c in 0..<4 {coarse[j*4+c]=diff[i*4+c]}
            }}
            coarse=solve(diff:coarse,unknown:flags,width:cw,height:ch)
            for y in 1..<h-1 {for x in 1..<w-1 where unknown[y*w+x] {
                let cx=Float(x)/2,cy=Float(y)/2,x0=min(cw-2,Int(cx)),y0=min(ch-2,Int(cy)),fx=cx-Float(x0),fy=cy-Float(y0)
                for c in 0..<3 {
                    result[(y*w+x)*4+c]=(coarse[(y0*cw+x0)*4+c]*(1-fx)+coarse[(y0*cw+x0+1)*4+c]*fx)*(1-fy)+(coarse[((y0+1)*cw+x0)*4+c]*(1-fx)+coarse[((y0+1)*cw+x0+1)*4+c]*fx)*fy
                }
            }}
        } else {
            var sums=[Float](repeating:0,count:3),n:Float=0
            for i in 0..<w*h where !unknown[i] {for c in 0..<3 {sums[c]+=diff[i*4+c]};n+=1}
            for i in 0..<w*h where unknown[i] {for c in 0..<3 {result[i*4+c]=sums[c]/max(1,n)}}
        }
        for iteration in 0..<72 {
            var residual:Float=0
            for parity in 0...1 {for y in 1..<h-1 {
                var x=1+((y+parity+1)%2)
                while x<w-1 {
                    let i=y*w+x
                    if unknown[i] {for c in 0..<3 {
                        let value=(result[(i-1)*4+c]+result[(i+1)*4+c]+result[(i-w)*4+c]+result[(i+w)*4+c])*0.25
                        residual=max(residual,abs(value-result[i*4+c]));result[i*4+c]=value
                    }}
                    x+=2
                }
            }}
            if iteration>8 && residual<0.00002 {break}
        }
        return result
    }
}

extension PortableHealing {
    /// The smooth correction field must retain the width of a thin stroke.
    /// A fixed maximum image edge can under-sample narrow, long repairs.
    package static func correctionSize(width:Double,height:Double,radius:Double)->(Int,Int) {
        let detailFactor=min(1,8/max(0.5,radius))
        let memoryFactor=sqrt(524288/max(1,width*height))
        let factor=min(1,memoryFactor,max(192/max(width,height),detailFactor))
        return (max(3,Int(ceil(width*factor))),max(3,Int(ceil(height*factor))))
    }
    package struct Point:Equatable {package var x:Double;package var y:Double;package init(x:Double,y:Double) {self.x=x;self.y=y}}
    private static func distance(_ p:Point,to a:Point,_ b:Point)->Double {
        let dx=b.x-a.x,dy=b.y-a.y,denominator=dx*dx+dy*dy
        let t=denominator>0 ? min(1,max(0,((p.x-a.x)*dx+(p.y-a.y)*dy)/denominator)):0
        return hypot(p.x-a.x-dx*t,p.y-a.y-dy*t)
    }
    private static func distance(_ p:Point,to path:[Point])->Double {
        guard let first=path.first else {return .infinity}
        if path.count==1 {return hypot(p.x-first.x,p.y-first.y)}
        var result=Double.infinity
        for i in 1..<path.count {result=min(result,distance(p,to:path[i-1],path[i]))}
        return result
    }
    /// Uniform arc-length samples avoid depending on pointer event frequency.
    private static func resampled(_ points:[Point],spacing:Double,limit:Int=64)->[Point] {
        guard let first=points.first else {return []}
        guard points.count>1 else {return [first]}
        var length=0.0
        for i in 1..<points.count {length+=hypot(points[i].x-points[i-1].x,points[i].y-points[i-1].y)}
        let step=max(spacing,length/Double(max(1,limit-1)))
        var result=[first],next=step,total=0.0
        for i in 1..<points.count {
            let a=points[i-1],b=points[i],segment=hypot(b.x-a.x,b.y-a.y)
            guard segment>0 else {continue}
            while next<=total+segment {
                let t=(next-total)/segment
                result.append(Point(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t));next+=step
            }
            total+=segment
        }
        if result.last != points.last {result.append(points.last!)}
        return result
    }
    /// Returns a normalized top-left source anchor from RGBA8 top-left rows.
    /// Context matching excludes the repair interior, while source interior
    /// outliers are penalized so another dust speck is not the preferred source.
    package static func findSource(pixels:[UInt8],width w:Int,height h:Int,points:[UnitPoint2D],radius:Double,variant:Int)->UnitPoint2D? {
        guard w>=5,h>=5,w<=32768,h<=32768,pixels.count>=w*h*4,!points.isEmpty,radius.isFinite,radius>=0,points.allSatisfy({$0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y)}) else {return nil}
        let outline=points.map {Point(x:$0.x*Double(w),y:$0.y*Double(h))}
        let path=resampled(outline,spacing:max(1,radius*0.8))
        let r=max(2,radius),minX=path.map(\.x).min()!-r-2,maxX=path.map(\.x).max()!+r+2,minY=path.map(\.y).min()!-r-2,maxY=path.map(\.y).max()!+r+2
        var ring:[(Int,Int)]=[],seen=Set<Int>()
        for p in path {for scale in [1.15,1.65] {for i in 0..<12 {
            let theta=Double(i)*Double.pi/6
            let x=Int((p.x+cos(theta)*r*scale).rounded()),y=Int((p.y+sin(theta)*r*scale).rounded())
            if x>1,y>1,x<w-2,y<h-2,distance(Point(x:Double(x),y:Double(y)),to:outline)>r*1.03,seen.insert(y*w+x).inserted {ring.append((x,y))}
        }}}
        guard !ring.isEmpty else {return nil}
        func rgb(_ x:Int,_ y:Int,_ c:Int)->Double {Double(pixels[(y*w+x)*4+c])/255}
        var targetMean=[Double](repeating:0,count:3)
        for (x,y) in ring {for c in 0..<3 {targetMean[c]+=rgb(x,y,c)/Double(ring.count)}}
        var candidates:[(score:Double,dx:Int,dy:Int)]=[],offsets=Set<Int64>()
        for level in [2.8,4.5,7.0,11.0,18.0,30.0,50.0] {for i in 0..<40 {
            let theta=Double(i)*Double.pi/20,dx=Int((cos(theta)*r*level).rounded()),dy=Int((sin(theta)*r*level).rounded())
            let key=(Int64(dx)<<32) ^ Int64(UInt32(bitPattern:Int32(dy)))
            guard offsets.insert(key).inserted,minX+Double(dx)>=0,maxX+Double(dx)<Double(w),minY+Double(dy)>=0,maxY+Double(dy)<Double(h) else {continue}
            if path.contains(where:{distance(Point(x:$0.x+Double(dx),y:$0.y+Double(dy)),to:outline)<r*2.1}) {continue}
            var valid=true,sourceMean=[Double](repeating:0,count:3),variance=[Double](repeating:0,count:3),error=0.0
            for (x,y) in ring {
                let xx=x+dx,yy=y+dy
                if xx<1 || yy<1 || xx>=w-1 || yy>=h-1 || pixels[(yy*w+xx)*4+3]<254 {valid=false;break}
                for c in 0..<3 {sourceMean[c]+=rgb(xx,yy,c)/Double(ring.count)}
            }
            guard valid else {continue}
            for (x,y) in ring {let xx=x+dx,yy=y+dy
                for c in 0..<3 {
                    let a=rgb(x,y,c)-targetMean[c],b=rgb(xx,yy,c)-sourceMean[c]
                    variance[c]+=b*b/Double(ring.count)
                    error+=(a-b)*(a-b)
                    let gx=(rgb(x+1,y,c)-rgb(x-1,y,c))-(rgb(xx+1,yy,c)-rgb(xx-1,yy,c))
                    let gy=(rgb(x,y+1,c)-rgb(x,y-1,c))-(rgb(xx,yy+1,c)-rgb(xx,yy-1,c))
                    error+=(gx*gx+gy*gy)*0.5
                }
            }
            error/=Double(ring.count)
            // A source that matches the boundary but contains an isolated defect
            // can otherwise beat clean candidates with equal boundary scores.
            var interiorPenalty=0.0,interiorCount=0
            for p in path {for offset in [Point(x:0,y:0),Point(x:r*0.45,y:0),Point(x:-r*0.45,y:0),Point(x:0,y:r*0.45),Point(x:0,y:-r*0.45)] {
                let xx=Int((p.x+Double(dx)+offset.x).rounded()),yy=Int((p.y+Double(dy)+offset.y).rounded())
                guard xx>=0,yy>=0,xx<w,yy<h,pixels[(yy*w+xx)*4+3]>=254 else {valid=false;continue}
                for c in 0..<3 {
                    let excursion=max(0,abs(rgb(xx,yy,c)-sourceMean[c])-max(0.06,4*sqrt(variance[c])))
                    interiorPenalty+=excursion*excursion
                }
                interiorCount+=1
            }}
            if valid {candidates.append((error+interiorPenalty/Double(max(1,interiorCount))*3+Double(dx*dx+dy*dy)/Double(w*w+h*h)*0.0004,dx,dy))}
        }}
        candidates.sort {if $0.score != $1.score {return $0.score<$1.score};if $0.dx != $1.dx {return $0.dx<$1.dx};return $0.dy<$1.dy}
        var diverse:[(score:Double,dx:Int,dy:Int)]=[]
        for candidate in candidates where !diverse.contains(where:{hypot(Double(candidate.dx-$0.dx),Double(candidate.dy-$0.dy))<r*0.7}) {diverse.append(candidate);if diverse.count==16 {break}}
        guard !diverse.isEmpty else {return nil}
        let chosen=diverse[Int(variant.magnitude%UInt(diverse.count))]
        return UnitPoint2D(x:points[0].x+Double(chosen.dx)/Double(w),y:points[0].y+Double(chosen.dy)/Double(h))
    }
}
