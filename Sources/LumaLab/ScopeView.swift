import LumaDomain
import SwiftUI

// Selection and layout belong to the platform UI; all bins/math are portable.
enum ScopeMode: String, CaseIterable {
    case waveform="波形", parade="RGB 分量", vectorscope="矢量示波器"
}
struct ScopePanel: View {
    @ObservedObject var model:EditorModel
    var body:some View {
        DisclosureGroup(isExpanded:$model.scopesExpanded) {
            Picker(L("分析模式"),selection:$model.scopeMode) {
                ForEach(ScopeMode.allCases,id:\.self) {Text(L($0.rawValue)).tag($0)}
            }.labelsHidden().pickerStyle(.menu).controlSize(.small)
            if let scopes=model.scopes {
                ScopePlot(data:scopes,mode:model.scopeMode).frame(height:132)
            } else {ProgressView().frame(height:132)}
            Text(L("基于当前显示预览的 sRGB 分布")).font(.system(size:9)).foregroundStyle(Palette.muted)
        } label:{Text(L("颜色分析")).font(.system(size:10,weight:.semibold))}
        .padding(.horizontal,18).padding(.bottom,12)
    }
}
struct ScopePlot:View {
    let data:ScopeAnalysis
    let mode:ScopeMode
    var body:some View {
        Canvas { context,size in
            let n=ScopeAnalysis.size, bounds=CGRect(origin:.zero,size:size)
            context.fill(Path(bounds),with:.color(.black.opacity(0.65)))
            var grid=Path()
            for i in 1...3 {let y=size.height*Double(i)/4;grid.move(to:CGPoint(x:0,y:y));grid.addLine(to:CGPoint(x:size.width,y:y))}
            context.stroke(grid,with:.color(.white.opacity(0.14)),lineWidth:0.5)
            if mode == .vectorscope {
                for radius in [0.25,0.5] {
                    let side=min(size.width,size.height)*radius*2
                    context.stroke(Path(ellipseIn:CGRect(x:(size.width-side)/2,y:(size.height-side)/2,width:side,height:side)),with:.color(.white.opacity(0.18)),lineWidth:0.5)
                }
                var axes=Path()
                axes.move(to:CGPoint(x:size.width/2,y:0));axes.addLine(to:CGPoint(x:size.width/2,y:size.height))
                axes.move(to:CGPoint(x:0,y:size.height/2));axes.addLine(to:CGPoint(x:size.width,y:size.height/2))
                context.stroke(axes,with:.color(.white.opacity(0.18)),lineWidth:0.5)
            }
            let planes = mode == .parade ? data.parade : [mode == .waveform ? data.waveform:data.vectorscope]
            for (channel,bins) in planes.enumerated() {
                let density=ScopeAnalysis.density(bins), span=size.width/Double(planes.count)
                let side=mode == .vectorscope ? min(size.width,size.height):span
                let cellWidth=side/Double(n), cellHeight=(mode == .vectorscope ? side:size.height)/Double(n)
                let xOffset=mode == .vectorscope ? (size.width-side)/2:Double(channel)*span
                for y in 0..<n {for x in 0..<n where density[y*n+x]>0 {
                    let color:Color
                    if mode == .parade {color=[Color.red,Color.green,Color.blue][channel]}
                    else if mode == .waveform {color=Color(white:0.9)}
                    else {
                        let cb=Double(x)/Double(n-1)-0.5,cr=0.5-Double(y)/Double(n-1)
                        color=Color(red:EngineColor.clamp(0.5+1.5748*cr),green:EngineColor.clamp(0.5-0.1873*cb-0.4681*cr),blue:EngineColor.clamp(0.5+1.8556*cb))
                    }
                    let rect=CGRect(x:xOffset+Double(x)*cellWidth,y:Double(y)*cellHeight,width:cellWidth+0.2,height:cellHeight+0.2)
                    context.fill(Path(rect),with:.color(color.opacity(0.15+0.85*density[y*n+x])))
                }}
            }
            if mode != .vectorscope {
                context.draw(Text(verbatim:"100%").font(.system(size:8)).foregroundColor(.gray),at:CGPoint(x:3,y:3),anchor:.topLeading)
                context.draw(Text(verbatim:"0%").font(.system(size:8)).foregroundColor(.gray),at:CGPoint(x:3,y:size.height-3),anchor:.bottomLeading)
                if mode == .parade {
                    for (i,title) in ["R","G","B"].enumerated() {context.draw(Text(verbatim:title).font(.system(size:9,weight:.bold)).foregroundColor([Color.red,.green,.blue][i]),at:CGPoint(x:(Double(i)+0.5)*size.width/3,y:4),anchor:.top)}
                }
            } else {
                let radius=min(size.width,size.height)/2
                for (title,r,g,b) in [("R",1.0,0.0,0.0),("Y",1.0,1.0,0.0),("G",0.0,1.0,0.0),("C",0.0,1.0,1.0),("B",0.0,0.0,1.0),("M",1.0,0.0,1.0)] {
                    let y=0.2126*r+0.7152*g+0.0722*b
                    let x=size.width/2+(b-y)/1.8556*radius*1.8
                    let v=size.height/2-(r-y)/1.5748*radius*1.8
                    context.draw(Text(verbatim:title).font(.system(size:8,weight:.bold)).foregroundColor(Color(red:r,green:g,blue:b)),at:CGPoint(x:x,y:v))
                }
            }
        }.accessibilityLabel(L(mode.rawValue))
    }
}
