import Foundation

package struct CurveSpline {
    package let points: [UnitPoint2D]
    private let slopes: [Double]
    package init(_ input: [UnitPoint2D]) {
        var ordered: [UnitPoint2D] = []
        for p in input.filter({$0.x.isFinite && $0.y.isFinite}).sorted(by:{$0.x < $1.x}) {
            if let last = ordered.last, abs(last.x-p.x) < 0.000001 { continue }
            ordered.append(p)
        }
        points = ordered
        guard ordered.count > 1 else { slopes = [Double](repeating:0,count:ordered.count); return }
        let n=ordered.count
        var widths=[Double](),deltas=[Double]()
        for i in 0..<(n-1) {
            let width=ordered[i+1].x-ordered[i].x
            widths.append(width); deltas.append((ordered[i+1].y-ordered[i].y)/width)
        }
        var m=[Double](repeating:0,count:n)
        if n==2 { m=[deltas[0],deltas[0]] }
        else {
            func endpoint(_ h0:Double,_ h1:Double,_ d0:Double,_ d1:Double)->Double {
                let result=((2*h0+h1)*d0-h0*d1)/(h0+h1)
                if result*d0<=0 {return 0}
                return d0*d1<0 && abs(result)>abs(3*d0) ? 3*d0 : result
            }
            m[0]=endpoint(widths[0],widths[1],deltas[0],deltas[1])
            m[n-1]=endpoint(widths[n-2],widths[n-3],deltas[n-2],deltas[n-3])
            for i in 1..<(n-1) where deltas[i-1]*deltas[i]>0 {
                let w1=2*widths[i]+widths[i-1],w2=widths[i]+2*widths[i-1]
                m[i]=(w1+w2)/(w1/deltas[i-1]+w2/deltas[i])
            }
        }
        slopes=m
    }
    package func value(at x: Double)->Double {
        guard let first=points.first,let last=points.last else {return x}
        if x<=first.x {return EngineColor.clamp(first.y)}
        if x>=last.x {return EngineColor.clamp(last.y)}
        let i=(1..<points.count).first(where:{x<=points[$0].x})! - 1
        let h=points[i+1].x-points[i].x,t=(x-points[i].x)/h,t2=t*t,t3=t*t*t
        let value=(2*t3-3*t2+1)*points[i].y+(t3-2*t2+t)*h*slopes[i]
            + (-2*t3+3*t2)*points[i+1].y+(t3-t2)*h*slopes[i+1]
        return EngineColor.clamp(value)
    }
}
