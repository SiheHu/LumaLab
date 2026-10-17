# Local automatic masks

This directory holds local ONNX model weights (ignored by Git), their original license notices,
input/output contracts, and source SHA-256 hashes in `MODELS.json`. Inference
runs locally through ONNX Runtime. The application never uploads photographs
and does not download model weights while editing.

## Face parsing

BiSeNet with ResNet18 from Yakhyokhuja Valikhujaev's MIT-licensed face-parsing
project. This checkpoint is optional, not redistributed, and not included in default setup. Its commercial / redistribution rights are unresolved because model authors document training on CelebAMask-HQ; see ../../MODEL_LICENSES.md. LumaLab uses the
published checkpoint without training or modifying the weights. Upstream:
https://github.com/yakhyo/face-parsing

Face detection currently uses an Apple Vision adapter to locate individuals.
Each face is expanded to a contextual crop, parsed into 19 semantic classes,
and projected back to normalized full-image coordinates. One mask is returned
per detected face, up to 20 individuals per operation. Face, face-and-neck skin,
hair, eyes and lips use distinct model classes. All Skin is a separate MediaPipe six-class semantic model. The detailed parser is not identity recognition or a face-box/skin-color approximation.

`PortableSegmentation` implements the shared preprocessing, categorical class
selection and reprojection. Semantic class membership has uniform interior
coverage; confidence is not treated as editing opacity. Boundary coverage is
bilinearly resampled when projected back to the photograph.

## Sky segmentation

U²-Net sky model from xiongzhu666, distributed as an FP16 ONNX conversion by
voyagerfromeast. Both the original repository and conversion model card declare
MIT. Sources:
https://github.com/xiongzhu666/Sky-Segmentation-and-Post-processing
https://huggingface.co/voyagerfromeast/skyseg

The model runs at 320 × 320 and returns a soft sky matte. LumaLab preserves
absolute sigmoid coverage. It does not min/max-normalize each photo, because
that could promote low-confidence output to a full-strength sky selection.
Small branches and fine edges can need manual brush refinement.

## Persistence and portability

Results are saved as `PortableMaskRaster`: width, height, row-major top-left
8-bit scalar coverage, and model identifier. JSON uses raw gray8 or an explicit
run-length encoding (value + UInt32 little-endian count), whichever is smaller.
Reopening an edit does not rerun inference. Saved masks do not require Apple
Vision or the model weights; they are suitable for a future Windows renderer.

The portable ONNX C ABI accepts Float32 NCHW and returns the first output as
Float32, with Float16 conversion when necessary. The supplied macOS build uses
CPUExecutionProvider with four intra-op threads. A Windows build can provide
the official Windows ONNX Runtime DLL to the same adapter. Windows execution
has not yet been validated in this release.

Subject/background and full-person segmentation currently use Apple Vision
adapters. The saved result is the same portable coverage representation. A
future portable detector/foreground model can replace those adapters without
changing existing edits.

## Content removal (LaMa)

The fixed-size FP32 LaMa ONNX export by Carve is included as `lama-fp32.onnx`.
Original LaMa authors: Roman Suvorov et al., Samsung Research; upstream is
Apache-2.0. The conversion model card also declares Apache-2.0. The original
license text is retained in `LICENSE-lama.txt`; exact sources and SHA-256 are
recorded in `MODELS.json`.

Sources:
https://github.com/advimman/lama
https://github.com/Carve-Photos/lama
https://huggingface.co/Carve/LaMa-ONNX

This model reconstructs masked content from nearby photographic context. It
can help remove objects and lines when copying a source patch is insufficient.
It has no text prompt, cloud service, diffusion model or Adobe dependency.
Reconstruction can still invent incorrect texture or structures.

The shared `PortableInpaintingProcessor` accepts top-left sRGB straight RGBA8
and gray8 ROI pixels, preserves aspect ratio while fitting a 512×512 model
canvas, reflects image context into padding, and conservatively reduces the
mask so thin lines are not lost. It returns native ROI dimensions. Mask-zero
bytes and the source alpha are retained exactly; mask-positive RGB receives
full prediction, leaving final feather and opacity blending to the renderer
once. Conversion helpers handle premultiplied decoder/renderer bytes.

Actual inference runs on the bundled ONNX Runtime CPU backend. Large source
ROIs are reconstructed from a 512px prediction, so fine texture may soften.
This is a complementary local content-removal mode, not a claim of Camera Raw
pixel equivalence or matching execution speed. Native preprocessing/compositing
is bounded to 20 million ROI pixels. The parent editor caches completed patches.

The model is about 208 MB. A source repository should store it with Git LFS or
provide a reproducible download with the recorded SHA-256; ordinary GitHub Git
uploads have a lower per-file limit. Installed app packages can bundle it with
its license notices for fully offline editing.

## All Skin and eyewear refinement

Google MediaPipe Selfie Multiclass (256×256), ONNX conversion by senty-au, supplies body-skin and face-skin classes separately from clothing and accessories. LumaLab combines a full-image pass with detected-person crops; macOS Vision supplies boxes / Eye Landmarks. NHWC RGB/255 input and NHWC logits are adapted explicitly. Optional detailed Face Parsing refines faces. Tiny/distant people and hard boundaries still require Brush refinement.

Detailed Face / Neck Skin can recover semantically misclassified transparent-lens pixels only when they match nearby identified skin, excluding eye openings and dark frames. Eyes are constrained to detected Eye Landmarks where available. No method can recover eyes hidden by opaque eyewear. These are new refinements, not a guarantee that every glass or reflection is resolved.
