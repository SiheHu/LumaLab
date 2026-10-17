# Third-party notices and license scope

Reviewed 2026-10-17. The root [MIT License](LICENSE) covers LumaLab-authored code and documentation, not third-party sources, model weights, trademarks or Apple frameworks. There is no single license that replaces all dependency licenses. “Permissive” here means permission to use, modify and redistribute LumaLab's own code, including commercially, with attribution; it does not clear optional model rights.

| Component | Use / distribution | Upstream license and required notices |
|---|---|---|
| [LibRaw 0.22.2](https://www.libraw.org/about) | Vendored C++ RAW decoder; statically linked by SwiftPM | **CDDL-1.0 selected** from the upstream LGPL-2.1 / CDDL-1.0 choice. Keep its source available under CDDL and retain [COPYRIGHT](Vendor/LibRaw-0.22.2/COPYRIGHT), [CDDL](Vendor/LibRaw-0.22.2/LICENSE.CDDL), [LGPL alternative](Vendor/LibRaw-0.22.2/LICENSE.LGPL) and file notices. This repository ships the upstream source needed to rebuild the library. Do not label it MIT. |
| dcraw portions in LibRaw | Included through LibRaw | Dave Coffin attribution and upstream file notices; LibRaw states it excludes restricted dcraw code. |
| DCB / FBDD portions in LibRaw | Included through LibRaw | Jacek Gozdz, BSD-3-Clause-style terms, retained in source headers and LibRaw additional notices below. |
| X3F portions in LibRaw | Included through LibRaw | Roland Karlsson, BSD-style terms, retained in source headers and additional notices. |
| DNG SDK fragments in LibRaw | Included through LibRaw | Adobe Systems Incorporated, permissive MIT-style notice. Publicly licensed upstream fragments are distinct from proprietary Camera Raw code. See LibRaw COPYRIGHT and original file notices. |
| [ONNX Runtime 1.20.1](https://github.com/microsoft/onnxruntime/tree/v1.20.1) | C API header vendored; official macOS arm64 library downloaded separately | [MIT](Vendor/ONNXRuntime/LICENSE), plus the full upstream [ThirdPartyNotices.txt](Vendor/ONNXRuntime/ThirdPartyNotices.txt). That aggregate includes notices for multiple build configurations; preserving it does not assert that every listed component is linked in this binary. |
| zlib | Linked from macOS, not vendored | [zlib license](https://zlib.net/zlib_license.html); authors Jean-loup Gailly and Mark Adler. System version depends on macOS. |
| Swift / SwiftUI / AppKit / Core Image / ImageIO / Vision / ColorSync / SF Symbols | Apple platform APIs and build tools; not redistributed by this source tree | Apple SDK / platform terms apply separately. They are not relicensed under MIT; macOS remains required for the current UI and renderer. |
| Model weights | Separate optional setup downloads, not committed | See [MODEL_LICENSES.md](MODEL_LICENSES.md), original license texts in Resources/AutoMasks, and exact hashes in MODELS.json. |

The original LibRaw archive is pinned to `LibRaw-0.22.2.tar.gz`, SHA-256 `de86b035655accff8d4010f1a221fdf50d353cb7b1422ba26f14a0db92612cfa`, from [libraw.org](https://www.libraw.org/data/LibRaw-0.22.2.tar.gz). Upstream source is unmodified; the LumaRaw.cpp / luma-include adapter files are LumaLab additions. The source-build and signature scripts allow rebuilding the complete application. Anyone distributing a binary must include the relevant notices and make the CDDL-covered source and modifications available; this source-only publication is not an installer release.

CDDL permits a larger work under other terms while preserving its covered source obligations; the MIT root does not erase those obligations. See CDDL sections 3.1–3.6. A distributor changing the licensing mode or dependency set must review the new combination.

No proprietary Camera Raw / Lightroom binaries, decompiled listings, photos, Firefly models, or Hopper installation are included. Development tools are credited in [CREDITS.md](CREDITS.md) and are not application runtime dependencies.
