# Roadmap

## Now: stabilize the macOS editor

- Real-photo verification of import → edit → mask → save → reopen → export.
- Better fine edges, transparent eyewear, Eye Landmarks and exposed-skin segmentation.
- RAW camera coverage, DNG metadata variants, memory / latency on large photographs.
- Reproducible fixtures and clearer error messages.

## Shared core and Windows

Schema, color math, LUT, Brush Coverage, Registration, Stack numerics, LibRaw and ONNX use shared Swift / C / C++ code. Windows still needs a UI, renderer / color-management adapters, platform detector replacements, build setup and real-machine tests. There is no release date or working Windows installer yet.

## Later

- Panorama projection / seam and Focus Stacking refinement.
- Model alternatives with clearer rights and stronger edge quality.
- Lens Profiles and broader color / export validation.
- Signing, notarization and install packages after the editing workflows are stable.

This is a direction, not a promise of feature parity with proprietary editors. Contributions should prioritize correctness over adding controls.


---

## 中文开发计划

### 当前重点：稳定 macOS 编辑流程

- 用真实照片检查从打开、调整、建立蒙版、保存、重新打开到导出的完整流程。
- 改善细小边缘、透明眼镜、眼部定位和裸露皮肤识别。
- 扩大相机 RAW 与不同 DNG 元数据的兼容性验证，检查高像素照片的内存占用与处理延迟。
- 增加可复现的测试样例，完善错误提示。

### 共享核心与 Windows

编辑参数结构、颜色计算、颜色查找表、画笔覆盖范围、图像配准、堆栈数值算法、LibRaw 和 ONNX 已使用共享的 Swift / C / C++ 代码。

Windows 仍需要界面、渲染器与色彩管理适配、系统识别功能的替代实现、构建流程和实机验证。目前没有可运行的 Windows 安装包，也尚未确定发布日期。

### 后续完善

- 改善全景拼接的投影与接缝，以及景深合成效果。
- 寻找授权更明确、边缘质量更好的模型替代方案。
- 增加镜头配置文件，扩大色彩与导出验证。
- 编辑流程稳定后，再处理签名、公证与安装包。

以上是开发方向，不是与商业编辑器功能等价的承诺。贡献应优先解决正确性和稳定性问题，再考虑增加控制项。
