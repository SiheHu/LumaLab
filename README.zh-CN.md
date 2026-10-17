<p align="center"><img src="docs/assets/overview.svg" alt="LumaLab 本机照片编辑与 Mask 工作流" width="1100"></p>

# LumaLab · 光影实验室

**在本机完成调色、Mask 与多张合成，保留可以继续修改的编辑参数。**

[English](README.md) · [Roadmap](docs/ROADMAP.md) · [Credits](CREDITS.md) · [Model License](MODEL_LICENSES.md)

LumaLab 是一款正在完善的桌面照片编辑器，把整体调色、局部 Mask、本机 Content Remove、多张合成和参数管理放在同一工作区。完成依赖下载后，照片处理在本机运行，不需要编辑器账号或云端 Inference 服务。

当前提供 **macOS 开发版源码**，主要在 Apple Silicon 验证。Shared Core 已拆分，Windows UI / Renderer 仍待开发，**目前没有可运行的 Windows 版本，也暂不提供安装包**。上图为使用原创合成风景绘制的界面概览，不是真实照片或性能测试结果。

## 已实现的工作流

| 工作 | 功能 |
|---|---|
| 整体调整 | Exposure、White Balance、带 Histogram 的平滑 RGB Curves、HSL、Color Grading、Detail、Grain、Vignette |
| 局部 Mask | Brush / Erase、Linear / Radial / Rectangle Gradient、Color / Luminance Range、Add / Subtract / Intersect、Local HSL |
| Mask 管理 | 每 Mask 独立 Overlay Color、Overlay / Control Points 开关，B/W Coverage、Group / Merge、Auto Mask Brush；重叠高亮正常叠加 |
| 自动识别 | Subject、People、Background、Sky、**All Skin**；可选 Face、Face / Neck Skin、Hair、Eyes、Glasses、Lips |
| 修复 | Clone、Heal、本机 LaMa Content Remove，保留可编辑笔触与 Source 控制 |
| 构图与对比 | Crop、Rotation、Perspective、Auto Crop、同步 Split / Reference View、触控板 Zoom / Pan |
| 风格复用 | 内置 / 自定义 Presets、Preset Amount、3D `.cube` LUT Import / Amount |
| 多张合成 | Mean / Median / Sigma-clipped Denoise、Star Trails、HDR Fusion / Deghost、Focus Stacking、Projective Panorama |
| 编辑管理 | 评分、关键词、相册、选择性 Batch Sync、Adaptive Mask Sync、History、Snapshots、Virtual Copies |
| 检查与输出 | ICC Soft Proofing、Gamut Warning；JPEG、PNG、8/16-bit TIFF，含 Color Space、Resize、Sharpening 与 Watermark |

## 保存方式

JPEG / PNG / BMP / TIFF 及支持的 RAW 按完整分辨率解码。RAW 优先用共享 LibRaw，不支持的部分变体尝试明确提示的 macOS RAW Fallback；失败时不会悄悄改用 Thumbnail。

- 普通图片按 `⌘S` 写入 `photo.ext.luma.json` Sidecar，原始图片字节不变。
- DNG 按 `⌘S` 写入内嵌 XMP 参数，保留 RAW Pixel Payload，但文件 Metadata 会改变；测试重要原图时保留备份。
- `.luma` Portable Project 包含源图与参数。参数属于 LumaLab 格式，不与 Adobe `crs` 互通。
- Crash Recovery 使用独立本机记录恢复异常退出前的工作，不代替显式 Save；正常关闭仍可选 Save / Discard / Cancel。

## 从源码运行

需要 macOS 13+、Swift 5.9+ 的 Xcode / Command Line Tools、Python 3。依赖下载阶段需要网络；当前固定的 ONNX Runtime 为 **macOS arm64**，没有 Intel / Windows Runtime 打包流程。Subject / Background 需要 macOS 14+。

```sh
git clone https://github.com/SiheHu/LumaLab.git
cd LumaLab
python3 scripts/fetch-dependencies.py
./scripts/build-app.sh
open dist/LumaLab.app
```

脚本从发布者处下载并校验 ONNX Runtime、Sky、LaMa、All Skin，合计数百 MB，不进入 Git。编辑时不会下载模型或上传照片。可用 `python3 scripts/fetch-dependencies.py --verify` 离线检查已有文件。

**Face Parsing 权重为可选组件。** 上游代码声明 MIT，但训练数据涉及非商业研究限制，权重的商用 / 再分发边界尚未明确。因此仓库不上传，也不默认下载。请先阅读 [MODEL_LICENSES.md](MODEL_LICENSES.md)；未安装时细分功能会说明缺少组件，All Skin 使用默认模型的较粗脸部结果。

首次启动**跟随系统语言**：中文系统偏好显示中文，否则使用 English。右上角设置或 `⌘,` 可选择中文、English、Follow System；已有明确选择继续保留。

## 测试与参与

```sh
./scripts/build-app.sh --self-test
swift run -c release LumaCoreChecks
python3 scripts/check-publication.py
```

完整 Image Checks 需要 macOS 图形服务与默认依赖；可选 Face 模型存在时才检查它。真实相机 DNG 可通过 `LUMALAB_DNG_FIXTURE=/绝对路径/your.dng` 自行提供，仓库不包含个人照片或 Adobe 示例素材。[测试说明](docs/TESTING.md)。

欢迎提供可复现 Bug、RAW 兼容性、复杂 Mask 边缘、色彩管理和大图性能反馈，也欢迎参与 Windows Renderer。[提交 Issue](https://github.com/SiheHu/LumaLab/issues/new?template=bug_report.yml) 时写清步骤、预期和实际结果，仅上传你有权公开的样例。[贡献说明](CONTRIBUTING.md)。

如果这个项目对你有帮助，欢迎点 Star，让更多摄影与开发者找到它；可复现反馈同样有帮助。

## 已知边界

目前不承诺 Camera Raw / Lightroom 的画质或性能等价。Glasses、反光、较小人物和复杂 Content Remove 仍可能失败；被不透明镜片挡住的眼睛无法恢复。All Skin 使用 256px Semantic Model，加上人物 Crop 和可选 Face 细化。算法更新不会自动改写已有保存 Mask，请重新生成 Automatic Mask 体验新版结果。

Panorama 暂为顺序重叠照片的 Planar Projective Registration / Feather Blend，可能出现视差和 Exposure Seam；Focus Stacking 可能有 Halo；HDR Fusion 输出 SDR。Lens Profile 库、32-bit HDR Export 与 Windows UI 尚未完成。[Roadmap](docs/ROADMAP.md)。

## License 与 Credits

原创代码采用 **MIT**；LibRaw 选择 **CDDL-1.0**，Runtime / Model 保留各自 License，不能统一改写成 MIT。请阅读 [Third-party Notices](THIRD_PARTY_NOTICES.md)、[Model License](MODEL_LICENSES.md) 与 [完整 Credits / 开发过程](CREDITS.md)。

项目由维护者提出需求并实测，OpenAI Codex 大量参与实现；早期研究使用 `reverse-engineer-anything` Skill / REA MCP 与 Hopper，运行软件不需要这些工具。公开仓库不包含 Adobe 私有 Binary、Disassembly、测试照片或权重；LibRaw 上游包含的公开授权 DNG SDK 片段保留原始声明。项目不隶属于 Adobe 或其他依赖发布者。
