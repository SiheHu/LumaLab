# Contributing / 参与开发

Start with a reproducible bug or a small proposal. LumaLab is still a development build; preserving original image data and saved-edit compatibility comes first.

1. Build using README instructions. Run relevant checks for your change.
2. For image processing, include a synthetic or explicitly redistributable fixture and describe the visible difference. Do not commit private photographs, model binaries, Sidecars, `.luma` sessions, secrets or proprietary research dumps.
3. Keep portable schema / math in LumaDomain or LumaCore. Place AppKit, Core Image, Vision and ColorSync behind macOS adapters. Windows is a target, not a currently supported product.
4. Document new Model provenance, exact hashes, preprocessing and original license. Do not treat a repository code license as automatic clearance for pretrained weights or training data.
5. Explain behavior, test evidence and remaining limits in the Pull Request. Contributions to project-authored code are under MIT; third-party-covered changes retain their applicable licenses. No CLA is required by this repository.

Useful first contributions: translation corrections, fixture coverage, import / save bugs, accessibility and UI issues. Larger renderer or model changes should start with an Issue.

中文：请优先提交可复现步骤与有权公开的样例；不要提交原始私人照片、编辑会话或模型权重。修改共享算法与平台 Adapter 时保持边界，新增 Model 必须同时记录来源、Hash、输入输出和 License。提交前运行相关检查，说明实际效果与仍未覆盖的情况。
