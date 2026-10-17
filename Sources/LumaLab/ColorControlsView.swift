import LumaDomain
import SwiftUI
import AppKit

struct ColorControlsView: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(spacing: 14) {
            InspectorSection(L("曲线"), symbol: "point.topleft.down.to.point.bottomright.curvepath", visible:model.sectionVisible(.curves),toggleVisibility:{model.toggleSection(.curves)}) {
                ToneCurveControls(model: model)
            }
            InspectorSection(L("混色器 · HSL"), symbol: "slider.horizontal.3", visible:model.sectionVisible(.hsl),toggleVisibility:{model.toggleSection(.hsl)}) {
                HSLControls(model: model)
            }
            InspectorSection(L("点颜色"), symbol: "eyedropper", visible:model.sectionVisible(.pointColor),toggleVisibility:{model.toggleSection(.pointColor)}) {
                PointColorControls(model: model)
            }
            InspectorSection(L("色彩分级"), symbol: "circle.hexagongrid", visible:model.sectionVisible(.grading),toggleVisibility:{model.toggleSection(.grading)}) {
                ColorGradingControls(model: model)
            }
            InspectorSection(L("相机校准"), symbol: "camera.aperture", visible:model.sectionVisible(.calibration),toggleVisibility:{model.toggleSection(.calibration)}) {
                calibration
            }
        }
    }
    private var calibration: some View {
        VStack(spacing: 0) {
            number("阴影色调", \.calibration.shadowTint)
            number("红原色色相", \.calibration.redHue)
            number("红原色饱和度", \.calibration.redSaturation)
            number("绿原色色相", \.calibration.greenHue)
            number("绿原色饱和度", \.calibration.greenSaturation)
            number("蓝原色色相", \.calibration.blueHue)
            number("蓝原色饱和度", \.calibration.blueSaturation)
            sectionResetButtons(resetAll:{model.resetSection(.calibration)})
        }
    }
    private func number(_ title: String, _ key: WritableKeyPath<EditState, Double>) -> some View {
        AdjustmentSlider(title: title, value: model.editBinding(key), range: -100...100, commit: { model.commit() })
    }
}

private enum CurveChannel: String, CaseIterable {
    case master = "RGB", red = "R", green = "G", blue = "B"
    var key: WritableKeyPath<EditState, [UnitPoint2D]> {
        switch self {
        case .master: return \.curves.master
        case .red: return \.curves.red
        case .green: return \.curves.green
        case .blue: return \.curves.blue
        }
    }
    var histogramIndex: Int? {switch self {case .master:return nil;case .red:return 0;case .green:return 1;case .blue:return 2}}
    var color: Color {
        switch self { case .master: return Palette.accent; case .red: return .red; case .green: return .green; case .blue: return .blue }
    }
}

struct ToneCurveControls: View {
    @ObservedObject var model: EditorModel
    @State private var channel = CurveChannel.master
    @State private var selected: Int?
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Picker(L("通道"),selection:$channel) {
                ForEach(CurveChannel.allCases,id:\.self) { Text(L($0.rawValue)).tag($0) }
            }.pickerStyle(.segmented).onChange(of:channel) { _ in selected=nil }
            CurveGraph(points:model.editBinding(channel.key),selected:$selected,color:channel.color,histogram:model.histogram,histogramChannel:channel.histogramIndex,commit:{model.commit()})
                .id(channel).frame(height:178)
            HStack {
                Text(L("点击空白添加点，拖动调整。")).font(.system(size:10)).foregroundStyle(Palette.muted)
                Spacer(minLength:0)
                Button(L("删除点")) { deletePoint() }.buttonStyle(.plain).font(.system(size:10))
                    .disabled(!canDelete)
            }
            Divider()
            Text(L("参数曲线")).font(.system(size:11,weight:.medium))
            VStack(spacing:0) {
                curveSlider("阴影",\.curves.shadows)
                curveSlider("暗调",\.curves.darks)
                curveSlider("亮调",\.curves.lights)
                curveSlider("高光",\.curves.highlights)
            }
            sectionResetButtons(resetAll:{model.resetSection(.curves);selected=nil},resetGroup:{
                model.editBinding(channel.key).wrappedValue=CurveSettings.line;selected=nil;model.commit()
            })
        }
    }
    private var canDelete: Bool { if let i=selected {return i>0 && i<model.edits[keyPath:channel.key].count-1};return false }
    private func deletePoint() {
        guard let index=selected else {return}
        var points=model.edits[keyPath:channel.key];CurveEditing.remove(index,from:&points)
        model.editBinding(channel.key).wrappedValue=points;selected=nil;model.commit()
    }
    private func curveSlider(_ title:String,_ key:WritableKeyPath<EditState,Double>) -> some View {
        AdjustmentSlider(title:title,value:model.editBinding(key),range:-100...100,commit:{model.commit()})
    }
}

private struct CurveGraph: View {
    @Binding var points:[UnitPoint2D]
    @Binding var selected:Int?
    var color:Color
    var histogram:[[Double]]
    var histogramChannel: Int?
    var commit:()->Void
    @State private var dragging:Int?
    var body:some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius:5).fill(Palette.background)
                HistogramView(channels:histogram,channel:histogramChannel).opacity(0.4).allowsHitTesting(false)
                Path { path in
                    for step in 1...3 {
                        let x=geo.size.width*CGFloat(step)/4,y=geo.size.height*CGFloat(step)/4
                        path.move(to:.init(x:x,y:0));path.addLine(to:.init(x:x,y:geo.size.height))
                        path.move(to:.init(x:0,y:y));path.addLine(to:.init(x:geo.size.width,y:y))
                    }
                }.stroke(Color.white.opacity(0.09),lineWidth:1)
                Path { path in
                    path.move(to:.init(x:0,y:geo.size.height));path.addLine(to:.init(x:geo.size.width,y:0))
                }.stroke(Color.white.opacity(0.16),style:.init(lineWidth:1,dash:[3,4]))
                Path { path in
                    let spline=CurveSpline(points)
                    for step in 0...256 {
                        let x=Double(step)/256
                        let point=CGPoint(x:x*geo.size.width,y:(1-spline.value(at:x))*geo.size.height)
                        if step==0 {path.move(to:point)} else {path.addLine(to:point)}
                    }
                }.stroke(color,style:.init(lineWidth:1.8,lineCap:.round,lineJoin:.round))
                ForEach(points.indices,id:\.self) { index in
                    Circle().fill(color).frame(width:selected==index ? 11:8,height:selected==index ? 11:8)
                        .overlay(Circle().stroke(selected==index ? Color.white:Palette.background,lineWidth:1.4))
                        .position(x:points[index].x*geo.size.width,y:(1-points[index].y)*geo.size.height)
                        .accessibilityLabel(L("曲线控制点 \(index+1)"))
                }
            }.contentShape(Rectangle()).coordinateSpace(name:"curveGraph")
                .gesture(DragGesture(minimumDistance:0,coordinateSpace:.named("curveGraph"))
                    .onChanged { event in
                        if dragging==nil {
                            let closest=points.indices.min {distance(points[$0],event.startLocation,geo.size)<distance(points[$1],event.startLocation,geo.size)}
                            if let i=closest,distance(points[i],event.startLocation,geo.size)<13 {dragging=i;selected=i}
                            else {
                                var next=points
                                let p=UnitPoint2D(x:Double(event.startLocation.x/geo.size.width),y:1-Double(event.startLocation.y/geo.size.height))
                                if let i=CurveEditing.insert(p,into:&next) {points=next;dragging=i;selected=i}
                            }
                        }
                        if let i=dragging {move(i,location:event.location,size:geo.size)}
                    }.onEnded {_ in dragging=nil;commit()})
        }.padding(5).background(Palette.background,in:RoundedRectangle(cornerRadius:5))
    }
    private func distance(_ point:UnitPoint2D,_ location:CGPoint,_ size:CGSize)->Double {
        hypot(point.x*size.width-location.x,(1-point.y)*size.height-location.y)
    }
    private func move(_ index:Int,location:CGPoint,size:CGSize) {
        guard points.indices.contains(index),size.width>0,size.height>0 else {return}
        var next=points
        let low=index==0 ? 0:next[index-1].x+0.005
        let high=index==next.count-1 ? 1:next[index+1].x-0.005
        let x=index==0 ? 0:index==next.count-1 ? 1:min(high,max(low,location.x/size.width))
        next[index]=UnitPoint2D(x:x,y:min(1,max(0,1-location.y/size.height)));points=next
    }
}

struct HSLControls: View {
    @ObservedObject var model: EditorModel
    var local: Bool = false
    @State private var selected = 0
    private let colors: [Color] = [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink]
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ForEach(bands.indices, id: \.self) { index in
                    Button { selected = index } label: {
                        Circle().fill(colors[index % colors.count]).frame(width: 18, height: 18)
                            .padding(3).overlay(Circle().stroke(selected == index ? Color.white : Color.clear, lineWidth: 1))
                    }.buttonStyle(.plain).help(L(bands[index].name))
                }
            }.frame(maxWidth: .infinity)
            if bands.indices.contains(selected) {
                Text(L("\(bands[selected].name)色范围")).font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 0) {
                    slider("色相", \.hue)
                    slider("饱和度", \.saturation)
                    slider("明亮度", \.luminance)
                }
            }
            sectionResetButtons(resetAll:{model.resetSection(.hsl,local:local)},resetGroup:{
                model.resetHSLBand(selected,local:local)
            })
        }
    }
    private var bands: [HSLBand] {local ? (model.selectedMask?.hsl ?? HSLBand.defaults) : model.edits.hsl}
    private func slider(_ title: String, _ key: WritableKeyPath<HSLBand, Double>) -> some View {
        let value = Binding<Double>(get: {
            bands.indices.contains(selected) ? bands[selected][keyPath: key] : 0
        }, set: { value in
            var bands = self.bands
            guard bands.indices.contains(selected) else { return }
            bands[selected][keyPath: key] = value
            if local {
                guard let index=model.selectedMaskIndex else {return}
                model.edits.masks[index].hsl=bands; model.requestRender()
            } else { model.editBinding(\.hsl).wrappedValue = bands }
        })
        return AdjustmentSlider(title: title, value: value, range: -100...100, commit: { model.commit() })
    }
}

private struct PointColorControls: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(L("启用点颜色"), isOn: model.editBinding(\.pointColor.enabled)).toggleStyle(.checkbox)
                .onChange(of: model.edits.pointColor.enabled) { _ in model.commit() }
            RGBColorWell(title: "目标颜色", rgb: model.editBinding(\.pointColor.color), commit: { model.commit() })
            Button {
                model.editBinding(\.pointColor.enabled).wrappedValue = true
                model.sampleMode = .pointColor
                model.commit()
            } label: { Label(L(model.sampleMode == .pointColor ? "请点击照片取色…" : "从照片取色"), systemImage: "eyedropper") }
                .buttonStyle(.bordered).controlSize(.small)
            Text(L("取样后，调整与目标颜色接近的区域。"))
                .font(.system(size: 10)).foregroundStyle(Palette.muted)
            AdjustmentSlider(title: "颜色范围", value: model.editBinding(\.pointColor.tolerance), range: 0.01...1, unit: "%", multiplier: 100, commit: { model.commit() })
            AdjustmentSlider(title: "色相", value: model.editBinding(\.pointColor.hue), range: -100...100, commit: { model.commit() })
            AdjustmentSlider(title: "饱和度", value: model.editBinding(\.pointColor.saturation), range: -100...100, commit: { model.commit() })
            AdjustmentSlider(title: "明亮度", value: model.editBinding(\.pointColor.luminance), range: -100...100, commit: { model.commit() })
            sectionResetButtons(resetAll:{model.resetSection(.pointColor)})
        }.font(.system(size: 11))
    }
}

private struct ColorGradingControls: View {
    @ObservedObject var model: EditorModel
    @State private var tone = 0
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                wheelSwatch(model.edits.grading.shadows, label: "阴影", index: 0)
                wheelSwatch(model.edits.grading.midtones, label: "中间调", index: 1)
                wheelSwatch(model.edits.grading.highlights, label: "高光", index: 2)
            }.frame(maxWidth: .infinity)
            Picker(L("色调范围"), selection: $tone) {
                Text(L("阴影")).tag(0); Text(L("中间调")).tag(1); Text(L("高光")).tag(2)
            }.pickerStyle(.segmented)
            VStack(spacing: 0) {
                AdjustmentSlider(title: "色相", value: wheelValue(\.hue), range: 0...360, unit: "°", colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], commit: { model.commit() })
                AdjustmentSlider(title: "饱和度", value: wheelValue(\.saturation), range: 0...100, commit: { model.commit() })
                AdjustmentSlider(title: "明亮度", value: wheelValue(\.luminance), range: -100...100, commit: { model.commit() })
                Divider().padding(.vertical, 8)
                AdjustmentSlider(title: "混合", value: model.editBinding(\.grading.blending), range: 0...100, defaultValue: 50, commit: { model.commit() })
                AdjustmentSlider(title: "平衡", value: model.editBinding(\.grading.balance), range: -100...100, commit: { model.commit() })
            }
            sectionResetButtons(resetAll:{model.resetSection(.grading)},resetGroup:{
                var grading=model.edits.grading;grading[keyPath:key]=GradingWheel();model.editBinding(\.grading).wrappedValue=grading;model.commit()
            })
        }
    }
    private var key: WritableKeyPath<ColorGrading, GradingWheel> { tone == 0 ? \.shadows : tone == 1 ? \.midtones : \.highlights }
    private func wheelValue(_ field: WritableKeyPath<GradingWheel, Double>) -> Binding<Double> {
        Binding(get: { model.edits.grading[keyPath: key][keyPath: field] }, set: { value in
            var grading = model.edits.grading
            grading[keyPath: key][keyPath: field] = value
            model.editBinding(\.grading).wrappedValue = grading
        })
    }
    private func wheelSwatch(_ value: GradingWheel, label: String, index: Int) -> some View {
        Button { tone = index } label: {
            VStack(spacing: 5) {
                Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                    .overlay(Circle().fill(Color(white: 0.15)).padding(9))
                    .overlay(Circle().fill(Color(hue: value.hue / 360 - floor(value.hue / 360), saturation: min(1,max(0,value.saturation / 100)), brightness: 0.85)).frame(width: 12, height: 12))
                    .frame(width: 47, height: 47)
                    .padding(3).overlay(Circle().stroke(tone == index ? Palette.accent : .clear, lineWidth: 1))
                Text(L(label)).font(.system(size: 10)).foregroundStyle(tone == index ? Palette.accent : Palette.muted)
            }
        }.buttonStyle(.plain)
    }
}

struct RGBColorWell: View {
    let title: String
    @Binding var rgb: [Double]
    let commit: () -> Void
    var body: some View {
        ColorPicker(title, selection: Binding(get: {
            Color(red: component(0), green: component(1), blue: component(2))
        }, set: { color in
            guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
            rgb = [c.redComponent, c.greenComponent, c.blueComponent]
            commit()
        }), supportsOpacity: false).font(.system(size: 11))
    }
    private func component(_ i: Int) -> Double { rgb.indices.contains(i) ? rgb[i] : 0.5 }
}

func resetButton(_ action: @escaping () -> Void) -> some View {
    Button(L("重置此组"), action: action).buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Palette.muted)
        .frame(maxWidth: .infinity, alignment: .trailing)
}
