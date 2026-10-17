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
