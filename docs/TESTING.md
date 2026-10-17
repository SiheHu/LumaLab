# Testing

Run `python3 scripts/fetch-dependencies.py`, then `./scripts/build-app.sh --self-test` on macOS with a graphical session. This exercises Image Engine, IO / Stack, Workflow, Geometry / Numeric Editing, DNG metadata, Repair, File Settings, Localization, Automatic Masks, Content Remove and Advanced features. Default downloads enable Sky / All Skin / LaMa checks. Face Parsing execution checks are conditional on its optional checkpoint being installed; pure Face / Glasses / Eye math tests always run.

`swift run -c release LumaCoreChecks` exercises Foundation / portable C++ algorithms without AppKit / Core Image / Vision or GUI services. This is the CI smoke test; it is not proof that a Windows app exists or that the full macOS UI is tested by CI.

Optional real-camera integration:

```sh
LUMALAB_DNG_FIXTURE=/absolute/path/to/your.dng ./scripts/build-app.sh --self-test
```

The DNG test writes temporary copies, verifies metadata round trips and compares RAW pixels. The source fixture is not uploaded. No installed Adobe product or proprietary sample asset is required.

For a local Mask regression study, an existing built App supports:

```sh
LUMALAB_MASK_PHOTO=/absolute/path/to/your.jpg LUMALAB_MASK_OUTPUT=/absolute/path/to/local-output dist/LumaLab.app/Contents/MacOS/LumaLab --automatic-mask-check
```

This needs the optional Face checkpoint for the Face / Neck Skin and Eyes photo passes, and writes only Coverage PNGs. Keep private derived masks out of Git, just like their source photographs.

Automated checks establish specific contracts, not photographic accuracy for every scene. Manually check transparent / opaque eyewear, different skin tones, clothing boundaries, tiny people, zoomed brush alignment, full-resolution exports and Save / Discard / Recovery before treating a build as stable. Newly generated masks use the current algorithm; saved masks retain their prior raster.

## Publication verification, 2026-10-17

A fresh source export, with no preinstalled weights, private fixtures or Adobe application, successfully downloaded and verified the default dependencies and passed the full available self-test. That baseline ran 176 Image Engine, 29 IO / Stack, 64 Workflow, 89 Revision, 147 synthetic DNG, 31 Repair, 1267 Localization, 35 Automatic Mask, 32 Content Remove, 44 Feature and 35 Advanced checks. Real-DNG integration was explicitly skipped because no opt-in fixture was supplied.

A separate local run with a user-owned camera DNG and optional Face checkpoint also passed the additional integration checks. A local glasses photo generated Face / Neck Skin, Eyes and All Skin masks for visual review, including hands and visible skin within transparent lenses. Neither the original photographs nor their derived masks are included here. One photo is not broad accuracy validation.
