# Architecture

| Layer | Responsibility | Platform status |
|---|---|---|
| LumaDomain | Edit schema, mask / repair persistence, curves / color math, LUT, Brush / semantic preprocessing, History / Recovery schema | Foundation; shared design |
| LumaCore | C ABI, C++ Brush Rasterization, Rigid / Projective Registration, Sigma Clipping | Portable C++17 |
| CLumaRaw | Pinned LibRaw sources and a bounded RGB16 / metadata adapter | Shared C++; macOS build verified |
| CAutomaticMask | Dynamic ONNX Runtime C ABI, Float32 / Float16 tensors, one- or two-input models | dlopen / LoadLibrary paths; Windows unverified |
| macOS adapters | PhotoIO, Core Image renderer, Vision detections, ColorSync Proof, IO / Recovery stores | macOS |
| UI | SwiftUI Inspector / Library / Sheets; AppKit viewport, pointer and close handling | macOS |

Decode → Repair in original coordinates → global color / LUT → local masks and HSL → geometry / crop → output color conversion. Mask coordinates are normalized top-left before geometry. Export uses full-resolution processing; display proxies do not alter document dimensions.

Sidecars, DNG private XMP and portable projects store LumaLab parameters. New fields have old-file defaults. Raw source bytes are not re-encoded when storing edits; DNG metadata is updated only by explicit Save. Recovery is a separate local journal and startup prompt, not silent photo saving.

Mask Overlay uses independent per-mask visibility / color and a view-level master switch. Selected masks are stronger than unselected masks; Source Over preserves overlap contributions. Control Points similarly combine master and per-mask visibility. These flags do not change exported adjustments. Group preserves members; Merge fixes the Coverage Union as a Raster and keeps the Active Mask adjustments.

Automatic Mask providers return portable gray8 coverage. Semantic kind / detection ordinal can be used by Adaptive Batch Sync to recompute on the destination; ordinal is not person identity. All Skin uses a six-class model with full-image / person crops. Optional detailed Face Parsing uses separate crops, semantic classes and Eye Landmarks. Eyewear repair is limited to accessory-class pixels matching nearby semantic skin; it does not turn a face box into a skin selector.

Model weights and runtime binaries are separately fetched with SHA-256 verification. Models / preprocessing are described in MODELS.json; rights and opt-in Face policy are in MODEL_LICENSES.md. Windows still needs UI, renderer, color-management and detector adapters plus build / runtime verification.

## Scopes, presets and export helpers

`LumaDomain/PhotoAnalysis.swift` contains bounded display-sRGB scope bins, recursive location-metadata filtering, LUT serialization and the state subset representable by a static RGB lookup. macOS supplies bitmap sampling, ImageIO encoding, native save panels and SwiftUI drawing. Component inversion is stored in the shared edit schema and applied before the component's add/subtract/intersect operation; legacy components default to uninverted.

LUT export samples the actual macOS pointwise color pipeline into a red-fastest 33 x 33 x 33 sRGB `.cube`. It excludes geometry, masks, repair, clarity, texture, sharpening, noise reduction, defringe, grain and vignette. It is not an Adobe preset or a replacement for an entire edit session.

Export estimates run off the main thread after a debounce. Small outputs use actual encoding; larger outputs extrapolate an encoded sample, separating metadata overhead. Stale estimates and scope results are discarded across document switches. New exports remove GPS/location metadata by default; old export presets preserve their existing policy until changed. Preset preview rasters live only in memory, while category and author strings round-trip in portable preset JSON.
