import Foundation

package struct CubeLUT: Codable, Equatable {
    package var name: String
    package var size: Int
    package var domainMin: [Double]
    package var domainMax: [Double]
    package var values: [Float]
    package enum Failure: Error { case invalid(String) }
    package init(text: String, name: String) throws {
        guard text.utf8.count <= 16 * 1024 * 1024 else { throw Failure.invalid("LUT exceeds 16 MiB") }
        self.name = name; size = 0; domainMin = [0,0,0]; domainMax = [1,1,1]; values = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard let first = parts.first else { continue }
            if first == "TITLE" { continue }
            if first == "LUT_3D_SIZE" {
                guard size == 0, parts.count == 2, let n = Int(parts[1]), (2...65).contains(n) else { throw Failure.invalid("Invalid 3D LUT size") }
                size = n
            } else if first == "DOMAIN_MIN" || first == "DOMAIN_MAX" {
                let numbers = parts.dropFirst().compactMap { Double($0) }
                guard numbers.count == 3, numbers.allSatisfy(\.isFinite) else { throw Failure.invalid("Invalid LUT domain") }
                if first == "DOMAIN_MIN" { domainMin = numbers } else { domainMax = numbers }
            } else {
                let numbers = parts.compactMap { Float($0) }
                guard numbers.count == 3, numbers.allSatisfy(\.isFinite), values.count < 65*65*65*3 else { throw Failure.invalid("Only numeric 3D .cube LUTs are supported") }
                values += numbers
            }
        }
        guard size >= 2, values.count == size*size*size*3,
              zip(domainMin,domainMax).allSatisfy({ $0 < $1 }) else { throw Failure.invalid("Incomplete LUT or invalid domain") }
    }
    package var isValid: Bool {
        (2...65).contains(size) && domainMin.count == 3 && domainMax.count == 3 && values.count == size*size*size*3 && values.allSatisfy(\.isFinite) && zip(domainMin,domainMax).allSatisfy { $0.isFinite && $1.isFinite && $0 < $1 }
    }
    package func apply(_ r: Double, _ g: Double, _ b: Double) -> (Double,Double,Double) {
        guard size >= 2, size <= 65, values.count == size*size*size*3, domainMin.count == 3, domainMax.count == 3 else { return (r,g,b) }
        let rgb = [r,g,b]
        var p=[Double]()
        for c in 0..<3 {
            let normalized=(rgb[c]-domainMin[c])/(domainMax[c]-domainMin[c])
            p.append(min(Double(size-1),max(0,normalized*Double(size-1))))
        }
        let lo = p.map { Int(floor($0)) }, hi = lo.map { min(size-1,$0+1) }
        let t = zip(p,lo).map { $0-Double($1) }
        var out = [Double](repeating:0,count:3)
        for z in 0...1 { for y in 0...1 { for x in 0...1 {
            let index = ((z == 0 ? lo[2] : hi[2])*size*size + (y == 0 ? lo[1] : hi[1])*size + (x == 0 ? lo[0] : hi[0]))*3
            let weight = (x == 0 ? 1-t[0] : t[0])*(y == 0 ? 1-t[1] : t[1])*(z == 0 ? 1-t[2] : t[2])
            for c in 0..<3 { out[c] += Double(values[index+c])*weight }
        } } }
        return (out[0],out[1],out[2])
    }
}

package struct LUTSettings: Codable, Equatable {
    package var cube: CubeLUT?
    package var amount: Double = 1
    package var enabled = true
    package init() {}
}
package struct EdgeBrushStroke: Codable, Equatable {
    package var points: [UnitPoint2D] = []
    package var color: [Double] = [0,0,0]
    package var tolerance: Double = 0.15
    package var diameter: Double = 0.07
    package var feather: Double = 0.75
    package var erase = false
    package var strength: Double = 1
    package init() {}
}

/// Color-connected brush coverage. Pixels beyond a contrasting barrier cannot be
/// reached from the path, even when a matching color exists on its far side.
package enum EdgeAwareBrush {
    package static func coverage(_ stroke: EdgeBrushStroke, rgba: [UInt8], width: Int, height: Int) -> [UInt8] {
        guard width>0,height>0,width<=32768,height<=32768,rgba.count==width*height*4,stroke.color.count==3 else {return []}
        let geometric = [UInt8](PortableBrush.raster(strokes:[stroke.points],width:width,height:height,diameterFraction:stroke.diameter,feather:stroke.feather))
        var result=[UInt8](repeating:0,count:width*height),visited=result
        var queue=[Int]();queue.reserveCapacity(min(width*height,262144))
        let tolerance=max(0.005,min(1,stroke.tolerance))
        func distance(_ i:Int)->Double {
            (0..<3).reduce(0.0) { $0+pow(Double(rgba[i*4+$1])/255-stroke.color[$1],2) }.squareRoot()/sqrt(3)
        }
        func push(_ i:Int) {
            guard visited[i]==0 else {return};visited[i]=1
            guard geometric[i]>0,distance(i)<tolerance else {return}
            queue.append(i)
        }
        for point in stroke.points {
            let x=min(width-1,max(0,Int(point.x*Double(width)))),y=min(height-1,max(0,Int(point.y*Double(height))))
            push(y*width+x)
        }
        var next=0
        while next<queue.count {
            let i=queue[next];next+=1
            let edge=min(1,max(0,(tolerance-distance(i))/(tolerance*0.25)))
            result[i]=UInt8(min(255,max(0,Double(geometric[i])*edge*min(1,max(0,stroke.strength)))))
            let x=i%width,y=i/width
            if x>0 {push(i-1)};if x+1<width {push(i+1)};if y>0 {push(i-width)};if y+1<height {push(i+width)}
        }
        return result
    }
}

package enum ComparisonLayout: String, CaseIterable { case single, splitVertical, splitHorizontal, reference }

package enum PresetInterpolation {
    /// Only color/effect fields are interpolated; geometry, masks and repairs stay put.
    package static func apply(base: EditState, target: EditState, amount: Double) -> EditState {
        let t=min(2,max(0,amount))
        guard t>0 else {return base}
        func mix(_ a:Any?,_ b:Any)->Any {
            if let b=b as? [String:Any] {
                let a=a as? [String:Any] ?? [:]
                return b.reduce(into:[String:Any]()) { out,pair in out[pair.key]=mix(a[pair.key],pair.value) }
            }
            if let b=b as? [Any],let a=a as? [Any],a.count==b.count {return zip(a,b).map {mix($0,$1)}}
            if let a=a as? NSNumber,let b=b as? NSNumber, String(cString:b.objCType) != "c",String(cString:a.objCType) != "c" {return a.doubleValue+(b.doubleValue-a.doubleValue)*t}
            return b
        }
        guard let a=try? JSONSerialization.jsonObject(with:JSONEncoder().encode(base)) as? [String:Any],
              var b=try? JSONSerialization.jsonObject(with:JSONEncoder().encode(target)) as? [String:Any] else {return target}
        for key in ["adjustments","hsl","grading","pointColor","calibration"] {if let value=b[key] {b[key]=mix(a[key],value)}}
        guard let data=try? JSONSerialization.data(withJSONObject:b),var result=try? JSONDecoder().decode(EditState.self,from:data) else {return target}
        func curve(_ a:[UnitPoint2D],_ b:[UnitPoint2D])->[UnitPoint2D] {
            let aa=CurveSpline(a),bb=CurveSpline(b)
            return (0...32).map {let x=Double($0)/32;return UnitPoint2D(x:x,y:min(1,max(0,aa.value(at:x)+(bb.value(at:x)-aa.value(at:x))*t)))}
        }
        result.curves.master=curve(base.curves.master,target.curves.master)
        result.curves.red=curve(base.curves.red,target.curves.red);result.curves.green=curve(base.curves.green,target.curves.green);result.curves.blue=curve(base.curves.blue,target.curves.blue)
        result.lut.amount=target.lut.amount*t
        return mergedSettings(result,into:base,color:true,geometry:false,masks:false)
    }
}
