import SwiftUI
import LumaDomain

struct AutomaticMaskControls: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L("自动识别")).font(.system(size: 11, weight: .medium))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                ForEach(AutomaticMaskKind.allCases) { kind in
                    Button { model.generateAutomaticMask(kind) } label: {
                        VStack(spacing: 5) {
                            Image(systemName: kind.symbol).font(.system(size: 15))
                            Text(L(kind.title)).font(.system(size: 10)).lineLimit(2).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity, minHeight: 50)
                            .background(Palette.raised, in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(model.editingLocked)
                }
            }
            Text(L("本机处理。多个人脸会分别建立选区；识别后可用添加或减去画笔细调。"))
                .font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

@MainActor extension EditorModel {
    func generateAutomaticMask(_ kind: AutomaticMaskKind) {
        guard !editingLocked, let source = source else { return }
        automaticMaskGeneration += 1
        let ticket = automaticMaskGeneration, document = documentID
        isGeneratingMask = true; automaticMaskTask = kind
        status = "正在识别\(kind.title)…"
        inferenceQueue.async { [weak self, renderer] in
            do {
                let image = try renderer.render(source: source, edits: .init(), maxDimension: 2048)
                let results = try AutomaticMaskService.shared.generate(kind, image: image)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.documentID == document, self.automaticMaskGeneration == ticket else { return }
                    self.isGeneratingMask = false; self.automaticMaskTask = nil
                    var first: UUID?
                    for (index,result) in results.enumerated() {
                        var mask = LocalMask(name: result.name, kind: .automatic)
                        mask.raster = result.raster;mask.automaticKind=kind;mask.automaticIndex=index
                        self.edits.masks.append(mask)
                        if first == nil { first = mask.id }
                    }
                    self.selectedMaskID = first; self.activeComponentID = nil
                    self.pendingShapePlacement = false; self.sampleMode = .none; self.tool = .masks
                    self.commit(); self.requestRender()
                    self.status = "已识别\(kind.title)，可调整局部参数或用画笔细调"
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.documentID == document, self.automaticMaskGeneration == ticket else { return }
                    self.isGeneratingMask = false; self.automaticMaskTask = nil
                    self.errorMessage = error.localizedDescription; self.status = "自动识别未完成，已有修改已保留"
                }
            }
        }
    }
    func cancelAutomaticMask() {
        automaticMaskGeneration += 1; isGeneratingMask = false; automaticMaskTask = nil
        status = "已取消自动识别"
    }
}
