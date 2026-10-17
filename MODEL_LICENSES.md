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
