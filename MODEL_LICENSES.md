# Model licenses / 模型授权

Reviewed **2026-10-17**. Model weights are **not covered by LumaLab's MIT License** and are not committed to Git. No models are trained by this project. Exact download URLs, input/output contracts and SHA-256 hashes are in [MODELS.json](Resources/AutoMasks/MODELS.json). Setup downloads from the original publishers; editing runs locally.

| Model | Author / source | Declared license | LumaLab policy |
|---|---|---|---|
| BiSeNet ResNet18 Face Parsing, 19 classes | [Yakhyokhuja Valikhujaev](https://github.com/yakhyo/face-parsing), building on face-parsing.PyTorch | Repository MIT; trained on CelebAMask-HQ | **Optional, not redistributed, not downloaded by default.** The [dataset agreement](https://github.com/switchablenorms/CelebAMask-HQ#dataset-agreement) restricts dataset / derived-data uses. Whether the published weights are independently cleared for commercial use and redistribution is unresolved. MIT code metadata alone is not commercial clearance for weights. |
| U²-Net Sky, FP16 ONNX | [xiongzhu666](https://github.com/xiongzhu666/Sky-Segmentation-and-Post-processing); [voyagerfromeast conversion](https://huggingface.co/voyagerfromeast/skyseg) | Upstream MIT; converter Model Card MIT | Default setup download; retain [original notice](Resources/AutoMasks/LICENSE-sky-segmentation.txt). Training-data rights are not independently audited by this project. |
| LaMa FP32 ONNX, 512×512 | [Roman Suvorov et al. / Samsung Research](https://github.com/advimman/lama); [Carve conversion](https://huggingface.co/Carve/LaMa-ONNX) | Upstream / conversion Model Card Apache-2.0 | Default setup download; retain [Apache License](Resources/AutoMasks/LICENSE-lama.txt) and author attribution. Conversion changes file format / export implementation; LumaLab does not modify weights. |
| Selfie Multiclass, 256×256, six classes | [Google MediaPipe](https://developers.google.com/edge/mediapipe/solutions/vision/image_segmenter); [senty-au ONNX conversion](https://huggingface.co/senty-au/selfie_multiclass_256x256-ONNX) | Google official Model Card and converter both declare Apache-2.0 | Default setup download; [Apache License](Resources/AutoMasks/LICENSE-selfie-skin.txt), credit Google LLC and senty-au. Used for Body / Face Skin, with landmark and optional detailed Face Parsing refinement. Intended for selfie / nearby-person framing; no guarantee for distant crowds or transparent / opaque eyewear. |
| Apple Vision Subject / People / Face Landmarks | Apple operating-system APIs | Apple SDK / platform terms | Used through macOS APIs, not vendored or relicensed. Saved Mask Rasters remain portable. |

Google’s [official Multiclass Model Card](https://storage.googleapis.com/mediapipe-assets/Model%20Card%20Multiclass%20Segmentation.pdf) names Adel Ahmadyan / Google and explicitly states Apache-2.0. It supports full-body imagery but does not promise pixel-perfect masks.

## Setup

```sh
python3 scripts/fetch-dependencies.py
python3 scripts/fetch-dependencies.py --verify
```

The optional fine Face Parsing model enables Face, Face / Neck Skin, Hair, Eyes, Glasses and Lips. Before obtaining it, review the linked publisher and dataset terms for your intended use. If appropriate for that use:

```sh
python3 scripts/fetch-dependencies.py --include-restricted-face
```

This flag is a deliberate download choice, **not a grant of rights or a commercial-use approval**. The public source retains the model adapter and displays a clear missing-component message when the optional weights are absent. All Skin, Sky, manual Masks, photo editing and local LaMa remain available with the default dependency set. All Skin uses a coarser face result when the optional parser is absent.

If publishing an App bundle, inspect its actual bundled weights: a local developer build can include optional files already present on that machine. Do not distribute the Face checkpoint until its rights have been independently resolved. This GitHub publication distributes source only, without model binaries or an installer.

## 中文说明

原创代码的 MIT 不覆盖第三方 Model。公开仓库不提交权重；默认下载 Sky、LaMa、Selfie Multiclass 和 ONNX Runtime。Face Parsing 权重单独选择，训练数据涉及非商业研究限制，不能因为上游代码写 MIT 就宣称该权重可自由商用。本机已有文件保留，但制作公开 App 时仍需单独核对权利。

模型声明与训练数据权利是两层问题。这里记录的是可核实的上游声明和本项目采取的分发边界，没有把未知权利改写为 MIT，也不把整个项目标为“仅限非商业”。发现上游授权变化时，请提交带链接的 Issue。


### 中文下载与使用教程

以下命令适用于当前 macOS 源码版本。默认固定的 ONNX Runtime 面向 Apple Silicon；Intel 和 Windows 的运行库打包流程尚未提供。

#### 一、进入源码目录

如果还没有下载源码，在终端执行：

```sh
git clone https://github.com/SiheHu/LumaLab.git
cd LumaLab
```

如果已经下载，只需在终端进入已有的 `LumaLab` 项目根目录，后续无需逐个寻找模型文件。

#### 二、下载默认依赖

```sh
python3 scripts/fetch-dependencies.py
```

脚本会从发布者处下载并校验 ONNX Runtime、天空识别模型、LaMa 内容补全模型和所有皮肤识别模型。网络仅在准备依赖时使用，编辑照片时不下载模型、不上传照片。

模型保存到 `Resources/AutoMasks/`，运行库保存到 `Vendor/ONNXRuntime/lib/`。这些二进制文件不进入 Git；下载地址、固定版本、输入输出格式和 SHA-256 校验值记录在 [MODELS.json](Resources/AutoMasks/MODELS.json)。

#### 三、按需下载面部细分模型

面部、面部与颈部皮肤、头发、眼睛、眼镜和嘴唇等细分功能使用可选模型。先阅读上方授权说明、发布者许可和数据集条款；如果适合你的用途，再执行：

```sh
python3 scripts/fetch-dependencies.py --include-restricted-face
```

这条命令会准备默认依赖，并额外下载面部细分权重。**该选项只是主动选择下载，不是授权证明，也不代表已经获准商用。**

不安装可选模型时，照片编辑、手动蒙版、天空识别、所有皮肤识别与本机内容移除仍可使用；所有皮肤识别采用较粗的脸部结果，细分功能会提示缺少组件。

#### 四、离线检查下载结果

只检查默认依赖：

```sh
python3 scripts/fetch-dependencies.py --verify
```

同时检查可选面部模型：

```sh
python3 scripts/fetch-dependencies.py --verify --include-restricted-face
```

检查模式不会访问网络；文件缺失或校验不匹配时会报告错误。需要补齐文件时，重新执行对应的下载命令，不加 `--verify`。

#### 五、重新构建并打开软件

```sh
./scripts/build-app.sh
open dist/LumaLab.app
```

下载模型本身不会更新已经运行的 App，需要重新构建并退出旧实例，再打开新版。构建流程会将本机已有模型打包到 App 中。

如果准备公开分发 App，请额外检查实际打包的权重。本机已经存在的可选面部模型也可能被打包；在权利尚未明确前，不应将该权重随公开安装包分发。当前 GitHub 仓库只发布源码，不提供模型二进制文件或安装包。
