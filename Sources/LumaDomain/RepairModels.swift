import Foundation

/// Source and target use the EXIF-oriented image's top-left normalized coordinates.
package enum RepairMode: String, Codable, CaseIterable, Identifiable {
    case heal, clone, inpaint
    package var id:String {rawValue}
}
package struct RepairStroke: Codable, Equatable, Identifiable {
    package var id=UUID()
    package var mode:RepairMode = .heal
    package var points:[UnitPoint2D] = []
    package var source=UnitPoint2D.center
    /// Radius as a fraction of the short image dimension.
    package var radius:Double = 0.015
    package var feather:Double = 0.5
    package var opacity:Double = 1
    package var enabled=true
    package var algorithmVersion=3
    package var anchor:UnitPoint2D {points.first ?? .center}
    package func moved(dx:Double,dy:Double)->RepairStroke {
        var result=self
        let loX=points.map(\.x).min() ?? 0, hiX=points.map(\.x).max() ?? 1
        let loY=points.map(\.y).min() ?? 0, hiY=points.map(\.y).max() ?? 1
        let x=min(1-hiX,max(-loX,dx)), y=min(1-hiY,max(-loY,dy))
        result.points=points.map {UnitPoint2D(x:$0.x+x,y:$0.y+y)}
        return result
    }

    package init(id: UUID = UUID(), mode: RepairMode = .heal, points: [UnitPoint2D] = [], source: UnitPoint2D = UnitPoint2D.center, radius: Double = 0.015, feather: Double = 0.5, opacity: Double = 1, enabled: Bool = true, algorithmVersion: Int = 3) {
        self.id = id; self.mode = mode; self.points = points; self.source = source; self.radius = radius; self.feather = feather; self.opacity = opacity; self.enabled = enabled; self.algorithmVersion = algorithmVersion
    }
}
