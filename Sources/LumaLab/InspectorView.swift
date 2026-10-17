import LumaDomain
import SwiftUI
import AppKit

struct InspectorView: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(spacing: 0) {
            HistogramView(channels: model.histogram).frame(height: 96).padding(.horizontal, 20).padding(.top, 18)
            HStack {
                Text(L("RGB 直方图")).font(.system(size: 9, weight: .semibold))
                Spacer()
                Text(L("\(model.dimensions) px")).font(.system(size: 9, design: .monospaced))
            }.foregroundStyle(Palette.muted).padding(.horizontal, 20).padding(.top, 9).padding(.bottom, 16)
            ScopePanel(model:model)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.tool == .edit { CreativeInspector(model:model); AdjustmentControls(model: model, local: false) }
                    else if model.tool == .crop { GeometryControls(model: model) }
                    else if model.tool == .repair { RepairInspector(model:model) }
                    else { MaskInspector(model: model) }
                }.padding(18)
            }.scrollIndicators(.hidden)
            if model.tool == .edit {
                Divider()
                Button { model.reset() } label: { Label(L("重置全部编辑"), systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity) }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.muted).padding(17)
            }
        }.background(Palette.panel)
    }
}

struct InspectorSection<Content: View>: View {
    private let title: String
    private let symbol: String
    private let content: Content
    private let visible: Bool
    private let toggleVisibility: (() -> Void)?
    @State private var expanded: Bool
    init(_ title: String, symbol: String, expanded: Bool = false, visible: Bool = true,
         toggleVisibility: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.symbol = symbol; self.content = content()
        self.visible = visible; self.toggleVisibility = toggleVisibility
        _expanded = State(initialValue: expanded)
    }
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:8) {
                Button { expanded.toggle() } label: {
                    HStack(spacing:7) {
                        Image(systemName:expanded ? "chevron.down" : "chevron.right").font(.system(size:10,weight:.semibold)).frame(width:12)
                        Label(L(title),systemImage:symbol)
                        Spacer(minLength:0)
                    }.font(.system(size:12,weight:.semibold)).foregroundStyle(Color(white:0.83))
                        .frame(maxWidth:.infinity,minHeight:25,alignment:.leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(L(title)).accessibilityValue(expanded ? "展开" : "收起")
                if let toggle = toggleVisibility { sectionEye(visible:visible,action:toggle) }
            }
            if expanded { content.padding(.top,14) }
        }.padding(.bottom,2)
    }
}

func sectionEye(visible: Bool, action: @escaping () -> Void) -> some View {
    Button(action:action) { Image(systemName:visible ? "eye" : "eye.slash").frame(width:20,height:24).contentShape(Rectangle()) }
        .buttonStyle(.plain).foregroundStyle(visible ? Palette.muted : Palette.accent)
        .accessibilityLabel(L(visible ? "隐藏此项效果" : "显示此项效果"))
}

func sectionResetButtons(resetAll: @escaping () -> Void, resetGroup: (() -> Void)? = nil) -> some View {
    HStack(spacing:16) {
        Spacer()
        Button(L("重置全部"),action:resetAll)
        if let resetGroup = resetGroup { Button(L("重置此组"),action:resetGroup) }
    }.buttonStyle(.plain).font(.system(size:10)).foregroundStyle(Palette.muted).padding(.top,7)
}

private struct AdjustmentControls: View {
    @ObservedObject var model: EditorModel
    var local: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L(local ? "局部调整" : "照片调整")).font(.system(size: 15, weight: .semibold))
                Spacer()
                sectionEye(visible:model.sectionVisible(.allAdjustments,local:local)) {model.toggleSection(.allAdjustments,local:local)}
            }
            section("白平衡",symbol:"thermometer.medium",id:.whiteBalance,expanded:true) { whiteBalance }
            section("光线",symbol:"sun.max",id:.light,expanded:true) { light }
            section("颜色",symbol:"circle.lefthalf.filled",id:.color,expanded:true) { color }
            section("质感与去朦胧",symbol:"sparkles",id:.effects) { effects }
            section("颗粒",symbol:"circle.dotted",id:.grain) { grain }
            section("暗角",symbol:"camera.metering.center.weighted",id:.vignette) { vignette }
            section("细节与降噪",symbol:"triangle",id:.detail) { detail }
            if !local {
                ColorControlsView(model: model)
                section("镜头校正",symbol:"camera.filters",id:.optics) { optics }
            }
        }
    }
    private var whiteBalance: some View {
        VStack(spacing: 0) {
            if !local {
                Button {
                    model.sampleMode = .whiteBalance
                } label: { Label(L(model.sampleMode == .whiteBalance ? "请点击中性灰区域…" : "白平衡取样"), systemImage: "eyedropper") }
                    .buttonStyle(.bordered).controlSize(.small).frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 12)
                    .help(L("在照片中点击应呈中性灰或白色的区域"))
            }
            slider("色温", \.temperature, colors: [.blue, .orange])
            slider("色调", \.tint, colors: [.green, .purple])
        }
    }
    private var light: some View {
        VStack(spacing: 0) {
            slider("曝光", \.exposure, range: -5...5, unit: " EV", precision: 2)
            slider("对比度", \.contrast)
            slider("高光", \.highlights)
            slider("阴影", \.shadows)
            slider("白色色阶", \.whites)
            slider("黑色色阶", \.blacks)
        }
    }
    private var color: some View {
        VStack(spacing: 0) {
            slider("自然饱和度", \.vibrance)
            slider("饱和度", \.saturation)
        }
    }
    private var effects: some View {
        VStack(spacing: 0) {
            slider("纹理", \.texture)
            slider("清晰度", \.clarity)
            slider("去朦胧", \.dehaze)
        }
    }
    private var grain: some View {
        VStack(spacing:0) {
            slider("颗粒强度", \.grain, range: 0...100)
            slider("颗粒大小", \.grainSize, range: 0...100, defaultValue: 25)
            slider("颗粒粗糙度", \.grainRoughness, range: 0...100, defaultValue: 50)
        }
    }
    private var vignette: some View {
        VStack(spacing:0) {
            slider("暗角强度", \.vignette)
            slider("暗角中点", \.vignetteMidpoint, range: 0...100, defaultValue: 50)
            slider("暗角羽化", \.vignetteFeather, range: 0...100, defaultValue: 75)
            slider("暗角圆度", \.vignetteRoundness)
        }
    }
    private var detail: some View {
        VStack(spacing: 0) {
            slider("锐化数量", \.sharpness, range: 0...100)
            slider("锐化半径", \.sharpenRadius, range: 0.3...3, precision: 1, defaultValue: 1)
            slider("锐化细节", \.sharpenDetail, range: 0...100, defaultValue: 25)
            slider("锐化边缘保护", \.sharpenMasking, range: 0...100)
            Divider().padding(.vertical, 8)
            slider("明亮度降噪", \.noiseReduction, range: 0...100)
            slider("颜色降噪", \.colorNoiseReduction, range: 0...100)
        }
    }
    private var optics: some View {
        VStack(spacing: 0) {
            slider("手动畸变", \.distortion)
            slider("去除色边", \.defringe, range: 0...100)
            Text(L("手动校正镜头畸变与色边。"))
                .font(.system(size: 10)).foregroundStyle(Palette.muted).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func section<C: View>(_ title: String, symbol: String, id: AdjustmentSection, expanded: Bool = false, @ViewBuilder content: () -> C) -> some View {
        InspectorSection(L(title),symbol:symbol,expanded:expanded,visible:model.sectionVisible(id,local:local),toggleVisibility:{model.toggleSection(id,local:local)}) {
            VStack(spacing:0) {
                content()
                sectionResetButtons(resetAll:{model.resetSection(id,local:local)})
            }
        }
    }
    private func slider(_ title: String, _ key: WritableKeyPath<Adjustments, Double>, range: ClosedRange<Double> = -100...100, unit: String = "", precision: Int = 0, defaultValue: Double = 0, colors: [Color]? = nil) -> some View {
        AdjustmentSlider(title: title, value: model.adjustment(key, local: local), range: range, unit: unit, precision: precision, colors: colors, defaultValue: defaultValue, commit: { model.commit() })
    }
}

private struct GeometryControls: View {
    @ObservedObject var model: EditorModel
    @State private var aspect = "自由"
    private let aspects = ["自由", "原始", "1:1", "4:3", "3:2", "16:9", "3:4", "2:3", "9:16"]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L("裁剪与几何")).font(.system(size:15,weight:.semibold)); Spacer()
                sectionEye(visible:model.sectionVisible(.geometry)) { model.toggleSection(.geometry) }
            }
            Text(L("拖动照片上的边框或角点调整裁剪；按住内部可移动裁剪框。"))
                .font(.system(size: 10)).foregroundStyle(Palette.muted).lineSpacing(3)
            Toggle(L("显示参考线"),isOn:$model.showGeometryGuides).toggleStyle(.checkbox)
            Picker(L("裁剪比例"), selection: $aspect) { ForEach(aspects, id: \.self) { Text(L($0)).tag($0) } }
                .onChange(of: aspect) { _ in applyAspect() }
            HStack {
                Button { model.rotate() } label: { Label(L("旋转 90°"), systemImage: "rotate.right") }
                Button { model.flip() } label: { Label(L("水平翻转"), systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
            }.buttonStyle(.bordered).controlSize(.small)
            AdjustmentSlider(title: "旋转", value: model.editBinding(\.geometry.angle), range: -45...45, unit: "°", precision: 1, commit: { model.commit() })
            InspectorSection(L("透视与变形"), symbol: "trapezoid.and.line.vertical", expanded: true, visible:model.sectionVisible(.transform),toggleVisibility:{model.toggleSection(.transform)}) {
                VStack(spacing: 0) {
                    geometrySlider("垂直透视", \.geometry.vertical)
                    geometrySlider("水平透视", \.geometry.horizontal)
                    geometrySlider("长宽比", \.geometry.aspect)
                    AdjustmentSlider(title: "缩放", value: model.editBinding(\.geometry.scale), range: 50...200, unit: "%", defaultValue: 100, commit: { model.commit() })
                    geometrySlider("水平位移", \.geometry.offsetX)
                    geometrySlider("垂直位移", \.geometry.offsetY)
                    Toggle(L("自动裁剪透明区域"),isOn:model.editBinding(\.geometry.autoCrop)).toggleStyle(.checkbox)
                        .onChange(of:model.edits.geometry.autoCrop) { _ in model.commit() }.padding(.vertical,8)
                    sectionResetButtons(resetAll:{model.resetSection(.transform)})
                }
            }
            sectionResetButtons(resetAll:{model.resetSection(.geometry);aspect="自由"},resetGroup:{model.resetCrop();aspect="自由"})
        }.font(.system(size: 11))
    }
    private func geometrySlider(_ title: String, _ key: WritableKeyPath<EditState, Double>) -> some View {
        AdjustmentSlider(title: title, value: model.editBinding(key), range: -100...100, inputFactor: 2, commit: { model.commit() })
    }
    private func applyAspect() {
        let ratio: Double?
        switch aspect {
        case "原始": ratio = model.sourceSize.width / max(model.sourceSize.height, 1)
        case "1:1": ratio = 1
        case "4:3": ratio = 4.0 / 3; case "3:2": ratio = 3.0 / 2
        case "16:9": ratio = 16.0 / 9; case "3:4": ratio = 3.0 / 4
        case "2:3": ratio = 2.0 / 3; case "9:16": ratio = 9.0 / 16
        default: ratio = nil
        }
        model.applyCropAspect(ratio)
    }
}

private struct MaskInspector: View {
    @ObservedObject var model: EditorModel
    @State private var componentKind = MaskKind.brush
    @State private var operation = MaskOperation.add
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L("局部选区")).font(.system(size:15,weight:.semibold)); Spacer()
                sectionEye(visible:model.sectionVisible(.masks)) { model.toggleSection(.masks) }
            }
            overlayOptions
            AutomaticMaskControls(model: model)
            Text(L("新建选区")).font(.system(size: 11, weight: .medium))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                ForEach(MaskKind.manualKinds) { kind in
                    Button { model.addMask(kind) } label: {
                        Label(L(kind.title), systemImage: kind.symbol).font(.system(size: 10))
                            .frame(maxWidth: .infinity, minHeight: 34).background(Palette.raised, in: RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain)
                }
            }
            maskList
            if let mask = model.selectedMask {
                selectedMaskControls(mask)
                Divider().padding(.vertical, 5)
                AdjustmentControls(model: model, local: true).disabled(!mask.enabled)
                InspectorSection(L("混色器 · HSL"),symbol:"slider.horizontal.3",visible:model.sectionVisible(.hsl,local:true),toggleVisibility:{model.toggleSection(.hsl,local:true)}) {
                    HSLControls(model:model,local:true)
                }.disabled(!mask.enabled)
            } else {
                Text(L("选择一种工具，再在照片上绘制选区。"))
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.vertical, 16)
            }
        }
    }
    private var overlayOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $model.showOverlay) {
                HStack { Label(L("所有选区高亮"), systemImage: "circle.dotted.circle.fill"); Spacer(); Text(L("O")).foregroundStyle(Palette.muted).font(.system(size: 10, design: .monospaced)) }
            }.toggleStyle(.switch).font(.system(size: 12, weight: .medium))
            Toggle(L("显示所有选区控制点"), isOn: $model.showHandles).toggleStyle(.checkbox).font(.system(size: 10))
        }.padding(11).background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
    }
    private func maskOverlayControls(_ mask: LocalMask) -> some View {
        HStack(spacing: 12) {
            ColorPicker(L("高亮颜色"),selection:Binding(get:{
                let c=model.edits.masks.first {$0.id==mask.id}?.overlayColor ?? mask.overlayColor
                return Color(red:c.count>0 ? c[0]:1,green:c.count>1 ? c[1]:0.12,blue:c.count>2 ? c[2]:0.1)
            },set:{color in
                guard let i=model.edits.masks.firstIndex(where:{$0.id==mask.id}) else {return}
                let c=NSColor(color).usingColorSpace(.sRGB) ?? .red
                model.edits.masks[i].overlayColor=[c.redComponent,c.greenComponent,c.blueComponent];model.commit();model.requestMaskOverlay()
            }),supportsOpacity:false)
            Spacer(minLength: 0)
            Toggle(L("黑白范围预览"),isOn:$model.coveragePreviewEnabled).toggleStyle(.checkbox)
        }.font(.system(size:10)).padding(.top,4)
    }
    private var maskList: some View {
        VStack(spacing: 6) {
            if model.edits.masks.count>1 {
                HStack {Button(L("分组")) {model.groupSelectedMasks()};Button(L("合并范围（保留当前调整）")) {model.mergeSelectedMasks()}.disabled(!model.maskSelection.contains(model.selectedMaskID ?? UUID()))}
                    .font(.system(size:9)).disabled(model.maskSelection.count<2)
                ForEach(Array(Set(model.edits.masks.compactMap(\.groupID))).sorted(by:{$0.uuidString<$1.uuidString}),id:\.self) {group in
                    HStack {
                        TextField(L("组选区名称"),text:Binding(get:{model.edits.masks.first {$0.groupID==group}?.groupName ?? L("组选区")},set:{model.renameMaskGroup(group,name:$0)})).textFieldStyle(.plain)
                        Button {model.toggleMaskGroup(group)} label:{Image(systemName:model.edits.masks.filter {$0.groupID==group}.allSatisfy(\.enabled) ? "eye":"eye.slash")}.buttonStyle(.plain)
                        Button(L("解除分组")) {model.ungroupMasks(group)}
                    }.font(.system(size:9))
                }
            }
            ForEach(model.edits.masks) { mask in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Toggle(L("选择以分组"),isOn:Binding(get:{model.maskSelection.contains(mask.id)},set:{if $0 {model.maskSelection.insert(mask.id);model.selectedMaskID=mask.id} else {model.maskSelection.remove(mask.id)}})).toggleStyle(.checkbox).labelsHidden().help(L("选择以分组"))
                        Button {
                            model.selectedMaskID = mask.id
                            model.selectComponent(id: nil)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: mask.kind.symbol)
                                VStack(alignment:.leading,spacing:2) {
                                    Text(localizedMaskName(mask)).lineLimit(1)
                                    if let group=mask.groupName {Text(L(group)).font(.system(size:8)).foregroundStyle(Palette.muted)}
                                }
                                Spacer(minLength: 0)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Button {model.setMaskOverlayVisible(mask.id,!mask.overlayVisible)} label: {
                            Image(systemName:mask.overlayVisible ? "circle.dotted.circle.fill":"circle.dotted")
                                .foregroundStyle(mask.overlayVisible ? Palette.accent:Palette.muted).frame(width:24,height:24).contentShape(Rectangle())
                        }.buttonStyle(.plain).help(L(mask.overlayVisible ? "隐藏此选区高亮":"显示此选区高亮"))
                            .accessibilityLabel(L(mask.overlayVisible ? "隐藏此选区高亮":"显示此选区高亮"))
                        Button {model.setMaskHandlesVisible(mask.id,!mask.handlesVisible)} label: {
                            Image(systemName:mask.handlesVisible ? "viewfinder":"viewfinder.circle")
                                .foregroundStyle(mask.handlesVisible ? Palette.accent:Palette.muted).frame(width:24,height:24).contentShape(Rectangle())
                        }.buttonStyle(.plain).help(L(mask.handlesVisible ? "隐藏此选区控制点":"显示此选区控制点"))
                            .accessibilityLabel(L(mask.handlesVisible ? "隐藏此选区控制点":"显示此选区控制点"))
                        Button { model.toggleMask(mask.id) } label: { Image(systemName: mask.enabled ? "eye" : "eye.slash").frame(width:24,height:24).contentShape(Rectangle()) }
                            .buttonStyle(.plain).help(L(mask.enabled ? "停用此选区" : "启用此选区"))
                    }
                    if model.selectedMaskID == mask.id { maskOverlayControls(mask) }
                }.font(.system(size: 11)).padding(10)
                    .foregroundStyle(model.selectedMaskID == mask.id ? Palette.accent : Color(white: 0.72))
                    .background(model.selectedMaskID == mask.id ? Palette.accent.opacity(0.08) : Palette.raised, in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }
    private func selectedMaskControls(_ mask: LocalMask) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(L("选区名称"), text: model.maskName()).textFieldStyle(.roundedBorder).onSubmit { model.commit() }
                .font(.system(size: 11)).help(L("为当前选区重命名"))
            HStack {
                Button { model.invertMask() } label: { Label(L("反向"), systemImage: "circle.lefthalf.filled").foregroundStyle(mask.inverted ? Palette.accent : Palette.muted) }
                Spacer()
                iconButton("square.on.square", help: "复制选区", action: model.duplicateMask)
                iconButton("trash", help: "删除选区", action: model.deleteMask)
            }.buttonStyle(.plain).font(.system(size: 11))
            AdjustmentSlider(title: "选区强度", value: model.maskValue(\.opacity), range: 0...1, unit: "%", multiplier: 100, defaultValue: 1, commit: { model.commit() })
            componentControls(mask)
            if let id=model.activeComponentID {
                Picker(L("组合方式"),selection:Binding(get:{model.activeShape?.operation ?? .add},set:{value in model.updateActiveShape {$0.operation=value};model.commit();model.requestRender()})) {
                    ForEach(MaskOperation.allCases) {Text(L($0.title)).tag($0)}
                }.controlSize(.small)
                Toggle(L("反转组成部分"),isOn:Binding(get:{model.activeShape?.inverted ?? false},set:{_ in model.invertComponent(id:id)})).toggleStyle(.checkbox).font(.system(size:10))
            }
            shapeControls(kind: activeKind(mask))
        }
    }
    private func componentControls(_ mask: LocalMask) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L("选区组成")).font(.system(size: 11, weight: .semibold))
            HStack {
                componentRow(title:"基础 · \(mask.kind.title)",symbol:mask.kind.symbol,id:nil)
                componentMenu(id:nil)
            }
            ForEach(Array(mask.components.enumerated()),id:\.element.id) { index,component in
                HStack(spacing:6) {
                    componentRow(title:"\(index+1). \(L(component.operation.title)) · \(L(component.kind.title))\(component.inverted ? " · " + L("反转") : "")",symbol:component.kind.symbol,id:component.id)
                    componentMenu(id:component.id)
                }.padding(.leading,10)
            }
            HStack {
                Picker(L("组合"), selection: $operation) { ForEach(MaskOperation.allCases) { Text(L($0.title)).tag($0) } }.labelsHidden()
                Picker(L("工具"), selection: $componentKind) { ForEach(MaskKind.manualKinds) { Text(L($0.title)).tag($0) } }.labelsHidden()
            }.controlSize(.small)
            Button {
                model.addComponent(kind: componentKind, operation: operation)
            } label: { Label(L("\(operation.title)选区范围"), systemImage: operation == .add ? "plus.circle" : operation == .subtract ? "minus.circle" : "circle.grid.cross") }
                .buttonStyle(.bordered).controlSize(.small)
        }.padding(10).background(Palette.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
    }
    private func componentMenu(id:UUID?) -> some View {
        Menu {
            Button(L("复制组成部分")) {model.duplicateComponent(id:id)}
            Button(L("复制并反转组成部分")) {model.duplicateComponent(id:id,inverted:true)}
            if let id {
                Button(L("反转组成部分")) {model.invertComponent(id:id)}
                Button(L("删除此组成部分")) {model.removeComponent(id:id)}
            }
        } label:{Image(systemName:"ellipsis.circle").frame(width:20,height:20).contentShape(Rectangle())}
        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel(L("组成部分操作"))
    }
    private func componentRow(title: String, symbol: String, id: UUID?) -> some View {
        Button { model.selectComponent(id: id) } label: {
            HStack(spacing: 6) {
                Image(systemName: model.activeComponentID == id ? "checkmark.circle.fill" : symbol)
                Text(L(title)).lineLimit(1); Spacer(minLength: 0)
            }.font(.system(size: 10)).foregroundStyle(model.activeComponentID == id ? Palette.accent : Palette.muted)
                .padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    @ViewBuilder private func shapeControls(kind: MaskKind) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if kind == .automatic {
                Text(L("识别结果已保存，可用添加或减去画笔细调范围。")).font(.system(size: 10)).foregroundStyle(Palette.muted)
            } else if kind == .colorRange {
                RGBColorWell(title: "取样颜色", rgb: rangeColorBinding, commit: { model.commit() }).padding(.bottom, 8)
                Button { model.sampleMode = .maskColor } label: { Label(L(model.sampleMode == .maskColor ? "请点击照片取色…" : "从照片取色"), systemImage: "eyedropper") }
                    .buttonStyle(.bordered).controlSize(.small).padding(.bottom, 9)
                shapeSlider("颜色容差", \.rangeTolerance, range: 0.01...1, defaultValue: 0.25)
            } else if kind == .luminanceRange {
                Button { model.sampleMode = .maskLuminance } label: { Label(L(model.sampleMode == .maskLuminance ? "请点击照片取样…" : "取样亮度"), systemImage: "eyedropper.halffull") }
                    .buttonStyle(.bordered).controlSize(.small).padding(.bottom, 9)
                shapeSlider("亮度下限", \.luminanceLow, defaultValue: 0.25)
                shapeSlider("亮度上限", \.luminanceHigh, defaultValue: 0.75)
            }
            if kind == .radial || kind == .rectangle {
                shapeSlider("渐变柔和度", \.feather, defaultValue: 0.75)
                Text(L("中心最强，边界为零；默认 75% 为线性衰减，柔和度调整整段渐变曲线。"))
                    .font(.system(size: 10)).foregroundStyle(Palette.muted).lineSpacing(3).padding(.bottom, 8)
            } else if kind != .automatic {
                shapeSlider("画笔羽化", \.feather, defaultValue: 0.75)
            }
            if kind == .brush {
                Toggle(L("自动边缘识别"),isOn:$model.autoMaskBrush).toggleStyle(.checkbox).font(.system(size:11))
                if model.autoMaskBrush {AdjustmentSlider(title:"边缘颜色容差",value:$model.autoMaskTolerance,range:0.01...0.5,unit:"%",multiplier:100,defaultValue:0.15,inputFactor:1,commit:{})}
                shapeSlider("画笔直径", \.brushSize, range: 0.005...0.35, defaultValue: 0.07)
                shapeSlider("流量", \.flow, defaultValue: 1)
                shapeSlider("密度", \.density, defaultValue: 1)
                Toggle(L("擦除画笔"), isOn: $model.brushErase).toggleStyle(.checkbox).font(.system(size: 11)).padding(.bottom, 8)
                Button(L("清空当前画笔")) { model.clearBrush() }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Palette.muted)
                Text(L("拖动涂抹；开启擦除可缩减当前范围。同一层重复涂抹不叠加色调，流量与密度控制选区强度。"))
                    .font(.system(size: 10)).foregroundStyle(Palette.muted).lineSpacing(3).padding(.top, 8)
            } else if kind == .colorRange || kind == .luminanceRange {
                Text(L("调整容差或亮度范围，可与其他组成部分相交、相加或相减。"))
                    .font(.system(size: 10)).foregroundStyle(Palette.muted).lineSpacing(3)
            } else if kind != .automatic {
                Text(L(model.pendingShapePlacement ? "在照片上拖动绘制一次。" : "拖动控制点调整形状，拖动内部移动；新增选区请使用上方工具。"))
                    .font(.system(size: 10)).foregroundStyle(Palette.muted).lineSpacing(3)
            }
        }
    }
    private func activeKind(_ mask: LocalMask) -> MaskKind {
        mask.components.first(where: { $0.id == model.activeComponentID })?.kind ?? mask.kind
    }
    private func shapeSlider(_ title: String, _ key: WritableKeyPath<MaskComponent, Double>, range: ClosedRange<Double> = 0...1, defaultValue: Double = 0) -> some View {
        AdjustmentSlider(title: title, value: model.maskShapeValue(key), range: range, unit: "%", multiplier: 100, defaultValue: defaultValue, inputFactor: key == \.feather ? 1 : 3, commit: { model.commit() })
    }
    private var rangeColorBinding: Binding<[Double]> {
        Binding(get: {
            guard let mask = model.selectedMask else { return [0.5, 0.5, 0.5] }
            return mask.components.first(where: { $0.id == model.activeComponentID })?.rangeColor ?? mask.rangeColor
        }, set: { rgb in
            guard let index = model.selectedMaskIndex else { return }
            if let component = model.edits.masks[index].components.firstIndex(where: { $0.id == model.activeComponentID }) {
                model.edits.masks[index].components[component].rangeColor = rgb
            } else { model.edits.masks[index].rangeColor = rgb }
            model.requestRender()
        })
    }
}

struct AdjustmentSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -100...100
    var unit: String = ""
    var precision: Int = 0
    var multiplier: Double = 1
    var colors: [Color]? = nil
    var defaultValue: Double = 0
    var inputFactor: Double = 3
    let commit: () -> Void
    @State private var draft = ""
    @State private var proposedValue: Double?
    @FocusState private var editing: Bool
    var body: some View {
        VStack(spacing:6) {
            HStack(spacing:4) {
                Text(L(title)).foregroundStyle(Color(white:0.73)); Spacer()
                TextField(L(title),text:Binding(get: { draft }, set: { text in
                    draft = text
                    if let next = NumericInput.parse(text, range: range, multiplier: multiplier, factor: inputFactor) {
                        proposedValue = next
                        if abs(next-value)>0.000001 { value=next }
                    }
                })).textFieldStyle(.plain).multilineTextAlignment(.trailing)
                    .font(.system(size:10,design:.monospaced)).foregroundStyle(abs(value-defaultValue)>0.0001 ? Palette.accent : Palette.muted)
                    .frame(width:66).padding(.vertical,3).padding(.horizontal,4)
                    .background(editing ? Palette.raised : .clear,in:RoundedRectangle(cornerRadius:3))
                    .focused($editing).onSubmit { applyInput(); editing=false }
                    .onChange(of:editing) { focused in if !focused { applyInput() } }
                    .accessibilityLabel(L(title + "数值"))
                if !unit.isEmpty { Text(L(unit)).font(.system(size:9)).foregroundStyle(Palette.muted) }
            }.font(.system(size:11))
            Slider(value:Binding(get:{min(range.upperBound,max(range.lowerBound,value))},set:{value=$0}),in:range,onEditingChanged:{if !$0 {commit()}})
                .controlSize(.mini).accessibilityLabel(L(title))
                .overlay(alignment:.bottom) {
                    if let colors = colors {
                        LinearGradient(colors:colors,startPoint:.leading,endPoint:.trailing).frame(height:1).offset(y:-3).allowsHitTesting(false)
                    }
                }
        }.padding(.bottom,11)
            .onAppear { refresh() }
            .onChange(of:value) { _ in if !editing || proposedValue != value {refresh()} }
    }
    private func refresh() { draft=String(format:"%.*f",precision,value*multiplier) }
    private func applyInput() {
        if let next=NumericInput.parse(draft,range:range,multiplier:multiplier,factor:inputFactor) {
            proposedValue=next;value=next;commit()
        }
        refresh()
    }
}
struct HistogramView: View {
    let channels: [[Double]]
    var channel: Int? = nil
    var body: some View {
        Canvas { context, size in
            for x in 1...3 {
                var grid = Path(); grid.move(to: .init(x: size.width * Double(x) / 4, y: 0)); grid.addLine(to: .init(x: size.width * Double(x) / 4, y: size.height))
                context.stroke(grid, with: .color(.white.opacity(0.04)), lineWidth: 1)
            }
            let colors: [Color] = [.red, .green, .blue]
            let selectedChannels = channel.map { channels.indices.contains($0) ? [channels[$0]] : [] } ?? channels
            let peak = max(selectedChannels.flatMap { $0 }.max() ?? 1, 0.001)
            for (index, bins) in channels.prefix(3).enumerated() {
                guard bins.count > 1, channel == nil || channel == index else { continue }
                var path = Path()
                path.move(to: .init(x: 0, y: size.height))
                for (i, bin) in bins.enumerated() {
                    let x = CGFloat(i) / CGFloat(bins.count - 1) * size.width
                    let y = size.height * (1 - CGFloat(pow(bin / peak, 0.55)) * 0.92)
                    path.addLine(to: .init(x: x, y: y))
                }
                path.addLine(to: .init(x: size.width, y: size.height)); path.closeSubpath()
                context.blendMode = .screen
                context.fill(path, with: .color(colors[index].opacity(0.3)))
                context.stroke(path, with: .color(colors[index].opacity(0.5)), lineWidth: 0.7)
            }
        }
        .background(Palette.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
        .accessibilityLabel(L("RGB 直方图"))
    }
}
