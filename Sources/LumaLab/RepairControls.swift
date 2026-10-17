import LumaDomain
import SwiftUI

struct RepairInspector:View {
    @ObservedObject var model:EditorModel
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Text(L("污点修复")).font(.system(size:16,weight:.semibold));Spacer()
                sectionEye(visible:model.sectionVisible(.repairs)) {model.toggleSection(.repairs)}
            }
            if model.isProcessingRepairs {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(L(model.repairProcessingTitle)).font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 0)
                }.padding(12).background(Palette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }
            Picker(L("模式"),selection:Binding(get:{model.selectedRepair?.mode ?? model.repairMode},set:{value in model.repairMode=value;if value == .inpaint {model.isPickingRepairSource=false};model.updateRepair {$0.mode=value};model.commit()})) {
                ForEach(RepairMode.allCases) {Text(L($0.title)).tag($0)}
            }.pickerStyle(.segmented)
            if activeMode == .inpaint {
                Text(L("涂满需要移除的物体，并稍微超出边缘。本机模型根据周围内容填补，适合电线、划痕和较大杂物；复杂纹理可能需要多次处理。"))
                    .font(.system(size:11)).foregroundStyle(Palette.muted).fixedSize(horizontal:false,vertical:true)
                Text(L("内圈完整移除，羽化只向外过渡；不透明度低于 100% 会保留部分原图。"))
                    .font(.system(size:10)).foregroundStyle(Palette.muted).fixedSize(horizontal:false,vertical:true)
            } else {
                Text(L("涂抹污点后自动取样。拖动取样点可换源；选中已有笔触可移动或修改。"))
                    .font(.system(size:11)).foregroundStyle(Palette.muted).fixedSize(horizontal:false,vertical:true)
                HStack {
                    Toggle(L("自动取样"),isOn:$model.repairAutoSample)
                    Spacer()
                    Button(L(model.isPickingRepairSource ? "取消取样":"手动取样")) {model.isPickingRepairSource.toggle()}
                }.font(.system(size:11))
            }
            Button {model.selectedRepairID=nil;model.repairDraft=[]} label:{Label(L("新建修复"),systemImage:"plus").frame(maxWidth:.infinity)}
            AdjustmentSlider(title:"画笔直径",value:repairValue(\.radius,defaultValue:\.repairRadius),range:0.001...0.1,unit:"%",precision:1,multiplier:200,commit:{model.commit()})
            AdjustmentSlider(title:"羽化",value:repairValue(\.feather,defaultValue:\.repairFeather),range:0...1,unit:"%",multiplier:100,inputFactor:1,commit:{model.commit()})
            AdjustmentSlider(title:"不透明度",value:repairValue(\.opacity,defaultValue:\.repairOpacity),range:0...1,unit:"%",multiplier:100,defaultValue:1,inputFactor:1,commit:{model.commit()})
            HStack {
                Toggle(L("显示控制点"),isOn:$model.showRepairHandles)
                Spacer()
                if activeMode != .inpaint { Button(L("重新取样")) {model.refreshRepairSource()}.disabled(model.selectedRepair==nil) }
            }.font(.system(size:11))
            Divider()
            Text(L("修复笔触 · \(model.edits.repairs.count)")).font(.system(size:11,weight:.medium)).foregroundStyle(Palette.muted)
            ForEach(Array(model.edits.repairs.enumerated()),id:\.element.id) {index,stroke in
                HStack(spacing:10) {
                    Button {model.selectedRepairID=stroke.id} label:{
                        HStack {Image(systemName:"bandage");Text(L("\(stroke.mode.title) \(index+1)"));Spacer()}.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Button {model.toggleRepair(stroke.id)} label:{Image(systemName:stroke.enabled ? "eye":"eye.slash")}.buttonStyle(.plain).accessibilityLabel(L("切换修复笔触 \(index+1) 可见"))
                    Button {model.deleteRepair(stroke.id)} label:{Image(systemName:"trash")}.buttonStyle(.plain).accessibilityLabel(L("删除修复笔触 \(index+1)"))
                }.font(.system(size:11)).padding(10)
                    .background(model.selectedRepairID==stroke.id ? Palette.accent.opacity(0.12):Palette.raised,in:RoundedRectangle(cornerRadius:5))
            }
            sectionResetButtons(resetAll:{model.resetSection(.repairs);model.selectedRepairID=nil})
        }
    }
    private var activeMode: RepairMode { model.selectedRepair?.mode ?? model.repairMode }
    private func repairValue(_ key:WritableKeyPath<RepairStroke,Double>,defaultValue:ReferenceWritableKeyPath<EditorModel,Double>)->Binding<Double> {
        Binding(get:{model.selectedRepair?[keyPath:key] ?? model[keyPath:defaultValue]},set:{value in
            model[keyPath:defaultValue]=value;model.updateRepair {$0[keyPath:key]=value}
        })
    }
}

@MainActor extension EditorModel {
    var selectedRepairIndex:Int? {edits.repairs.firstIndex {$0.id==selectedRepairID}}
    var selectedRepair:RepairStroke? {selectedRepairIndex.map {edits.repairs[$0]}}
    func updateRepair(_ body:(inout RepairStroke)->Void) {
        guard !editingLocked,let index=selectedRepairIndex else {return}
        body(&edits.repairs[index]);edits.repairs[index].algorithmVersion = 3;requestRender()
    }
    func toggleRepair(_ id:UUID) {
        guard !editingLocked,let i=edits.repairs.firstIndex(where:{$0.id==id}) else {return}
        edits.repairs[i].enabled.toggle();commit();requestRender()
    }
    func deleteRepair(_ id:UUID) {
        guard !editingLocked else {return}
        edits.repairs.removeAll {$0.id==id}
        if selectedRepairID==id {selectedRepairID=nil}
        commit();requestRender()
    }
    func completeRepairStroke() {
        guard !repairDraft.isEmpty,!editingLocked else {return}
        var stroke=RepairStroke();stroke.mode=repairMode;stroke.radius=repairRadius;stroke.feather=repairFeather;stroke.opacity=repairOpacity
        stroke.points=repairDraft;repairDraft=[]
        if stroke.mode == .inpaint {
            edits.repairs.append(stroke);selectedRepairID=stroke.id;commit();requestRender();return
        }
        if !repairAutoSample {
            guard let selected=repairManualSource else {errorMessage="请先点击手动取样，在照片上选择取样位置。";return}
            stroke.source=selected;edits.repairs.append(stroke);selectedRepairID=stroke.id;commit();requestRender();return
        }
        resolveRepair(stroke:stroke,replacing:nil)
    }
    func refreshRepairSource() {
        guard let stroke=selectedRepair,!editingLocked else {return}
        repairVariant+=1;resolveRepair(stroke:stroke,replacing:stroke.id)
    }
    private func resolveRepair(stroke:RepairStroke,replacing:UUID?) {
        guard let source=source else {return}
        repairSearchGeneration+=1;let ticket=repairSearchGeneration
        let before=replacing.flatMap {id in edits.repairs.firstIndex {$0.id==id}}.map {Array(edits.repairs.prefix($0))} ?? edits.repairs
        let variant=repairVariant
        isFindingRepairSource=true;status="正在匹配取样区域…"
        renderQueue.async { [weak self,renderer] in
            do {
                let repaired=try renderer.repairProcessor.apply(source:source,strokes:before)
                var updated=stroke
                updated.source=try renderer.repairProcessor.findSource(for:stroke,in:repaired,variant:variant)
                let result=updated
                DispatchQueue.main.async {
                    guard let self=self,self.repairSearchGeneration==ticket else {return}
                    self.isFindingRepairSource=false
                    if let id=replacing,let i=self.edits.repairs.firstIndex(where:{$0.id==id}) {self.edits.repairs[i]=result}
                    else {self.edits.repairs.append(result)}
                    self.selectedRepairID=result.id;self.commit();self.requestRender()
                }
            } catch { DispatchQueue.main.async {
                guard let self=self,self.repairSearchGeneration==ticket else {return}
                self.isFindingRepairSource=false;self.errorMessage=error.localizedDescription
                self.status="未找到可用取样，请减小笔触或调整位置后重试"
            }}
        }
    }
}

struct RepairGuide:View {
    var strokes:[RepairStroke]
    var selected:UUID?
    var draft:[UnitPoint2D]
    var radius:Double
    var scale:CGFloat
    var body:some View {
        Canvas {context,size in
            func point(_ p:UnitPoint2D)->CGPoint {CGPoint(x:p.x*size.width,y:p.y*size.height)}
            func outline(_ points:[UnitPoint2D],radius:Double,color:Color) {
                guard let anchor=points.first else {return}
                let r=radius*min(size.width,size.height)
                if points.count==1 {context.stroke(Path(ellipseIn:CGRect(x:point(anchor).x-r,y:point(anchor).y-r,width:r*2,height:r*2)),with:.color(color),lineWidth:1/scale)}
                else {
                    var path=Path();path.addLines(points.map(point))
                    context.stroke(path,with:.color(color.opacity(0.15)),style:StrokeStyle(lineWidth:r*2,lineCap:.round,lineJoin:.round))
                    context.stroke(path,with:.color(color),style:StrokeStyle(lineWidth:1/scale,dash:[4/scale,3/scale]))
                }
            }
            for stroke in strokes where stroke.enabled {
                let p=point(stroke.anchor),active=stroke.id==selected
                if active {
                    outline(stroke.points,radius:stroke.radius,color:.white)
                    if stroke.mode != .inpaint {
                    let offset=UnitPoint2D(x:stroke.source.x-stroke.anchor.x,y:stroke.source.y-stroke.anchor.y)
                    outline(stroke.points.map {UnitPoint2D(x:$0.x+offset.x,y:$0.y+offset.y)},radius:stroke.radius,color:Palette.accent)
                    var link=Path();link.move(to:p);link.addLine(to:point(stroke.source))
                    context.stroke(link,with:.color(Palette.accent.opacity(0.8)),style:StrokeStyle(lineWidth:1/scale,dash:[3/scale,3/scale]))
                    let s=point(stroke.source)
                    context.fill(Path(ellipseIn:CGRect(x:s.x-4/scale,y:s.y-4/scale,width:8/scale,height:8/scale)),with:.color(Palette.accent))
                    }
                }
                context.fill(Path(ellipseIn:CGRect(x:p.x-3/scale,y:p.y-3/scale,width:6/scale,height:6/scale)),with:.color(active ? .white:Palette.muted))
            }
            outline(draft,radius:radius,color:Palette.accent)
        }.accessibilityLabel(L("修复目标与取样控制点"))
    }
}
