#!/bin/bash
# Build a local, ad-hoc-signed macOS app without changing the machine's toolchain.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FINAL_APP="$ROOT/dist/LumaLab.app"
BUILD_DIR="$ROOT/.build"
RUN_SELF_TEST=0
MAKE_ZIP=0
for arg in "$@"; do
  case "$arg" in
    --self-test) RUN_SELF_TEST=1 ;;
    --zip) MAKE_ZIP=1 ;;
    --help|-h) printf 'Usage: %s [--self-test] [--zip]\n' "$0"; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

# Override only for this command; no global xcode-select or shell profile changes.
DEV_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
export DEVELOPER_DIR="$DEV_DIR"
SWIFT="$DEV_DIR/usr/bin/swift"
SWIFTC="$DEV_DIR/usr/bin/swiftc"
if [[ ! -x "$SWIFT" || ! -x "$SWIFTC" ]]; then
  printf 'Swift toolchain unavailable at %s. Install Xcode Command Line Tools or set DEVELOPER_DIR.\n' "$DEV_DIR" >&2
  exit 1
fi
if [[ -n "${LUMALAB_SDK:-}" ]]; then
  SDK="$LUMALAB_SDK"
elif [[ -d "$DEV_DIR/SDKs/MacOSX14.4.sdk" ]]; then
  SDK="$DEV_DIR/SDKs/MacOSX14.4.sdk"
else
  SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
fi
ARCH="${LUMALAB_ARCH:-$(/usr/bin/uname -m)}"
case "$ARCH" in arm64|x86_64) ;; *) printf 'Unsupported architecture: %s\n' "$ARCH" >&2; exit 1 ;; esac
TRIPLE="$ARCH-apple-macosx13.0"
mkdir -p "$BUILD_DIR/module-cache" "$ROOT/dist"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_DIR/module-cache"
# Pin host SDK and target: older CLT may otherwise misidentify a newer macOS host.
BUILD_ARGS=(--package-path "$ROOT" --scratch-path "$BUILD_DIR" --cache-path "$BUILD_DIR/cache" --config-path "$BUILD_DIR/config" --security-path "$BUILD_DIR/security" --manifest-cache local --disable-sandbox --configuration release --product LumaLab --triple "$TRIPLE" --sdk "$SDK" -Xswiftc -module-cache-path -Xswiftc "$BUILD_DIR/module-cache")
printf 'Building LumaLab for %s with %s\n' "$TRIPLE" "$SDK"
"$SWIFT" build "${BUILD_ARGS[@]}"
BIN_DIR="$("$SWIFT" build "${BUILD_ARGS[@]}" --show-bin-path)"
[[ -x "$BIN_DIR/LumaLab" ]] || { printf 'Built executable not found.\n' >&2; exit 1; }

# Sign outside Documents: its file provider can race to add FinderInfo while
# codesign scans a newly created .app. Stage only this generated build product.
STAGING_ROOT="$(/usr/bin/mktemp -d /private/tmp/lumalab-package.XXXXXX)"
trap 'rm -rf "$STAGING_ROOT"' EXIT
APP="$STAGING_ROOT/LumaLab.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/LumaLab" "$APP/Contents/MacOS/LumaLab"
cp "$ROOT/scripts/Info.plist" "$APP/Contents/Info.plist"
# Model weights and runtime live behind a portable C ABI. Bundle paths are
# relative to the app, so moving it never depends on the developer checkout.
if [[ -d "$ROOT/Resources/AutoMasks" ]]; then
  /usr/bin/ditto --norsrc --noextattr "$ROOT/Resources/AutoMasks" "$APP/Contents/Resources/AutoMasks"
fi
if [[ -f "$ROOT/Vendor/ONNXRuntime/lib/libonnxruntime.1.20.1.dylib" ]]; then
  mkdir -p "$APP/Contents/Frameworks" "$APP/Contents/Resources/ThirdParty/ONNXRuntime"
  cp "$ROOT/Vendor/ONNXRuntime/lib/libonnxruntime.1.20.1.dylib" "$APP/Contents/Frameworks/"
  cp "$ROOT/Vendor/ONNXRuntime/LICENSE" "$APP/Contents/Resources/ThirdParty/ONNXRuntime/"
  cp "$ROOT/Vendor/ONNXRuntime/ThirdPartyNotices.txt" "$APP/Contents/Resources/ThirdParty/ONNXRuntime/"
fi
mkdir -p "$APP/Contents/Resources/ThirdParty/LibRaw"
cp "$ROOT/Vendor/LibRaw-0.22.2/LICENSE.CDDL" "$ROOT/Vendor/LibRaw-0.22.2/LICENSE.LGPL" "$ROOT/Vendor/LibRaw-0.22.2/COPYRIGHT" "$APP/Contents/Resources/ThirdParty/LibRaw/"
cp "$ROOT/Vendor/LibRaw-0.22.2/LUMALAB_ADDITIONAL_NOTICES.txt" "$APP/Contents/Resources/ThirdParty/LibRaw/"
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$ROOT/MODEL_LICENSES.md" "$ROOT/CREDITS.md" "$APP/Contents/Resources/ThirdParty/"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"

ICON_WORK="$BUILD_DIR/app-icon"
mkdir -p "$ICON_WORK"
"$SWIFTC" -target "$TRIPLE" -sdk "$SDK" -module-cache-path "$BUILD_DIR/module-cache" "$ROOT/scripts/make-icon.swift" -o "$ICON_WORK/make-icon"
"$ICON_WORK/make-icon" "$ICON_WORK/source.png" "$APP/Contents/Resources/LumaLab.icns"
# Clear inherited metadata only from this generated build product.
/usr/bin/xattr -cr "$APP"
if [[ -x /usr/bin/codesign ]]; then
  if [[ -f "$APP/Contents/Frameworks/libonnxruntime.1.20.1.dylib" ]]; then
    /usr/bin/codesign --force --sign - "$APP/Contents/Frameworks/libonnxruntime.1.20.1.dylib"
  fi
  /usr/bin/codesign --force --sign - "$APP"
  /usr/bin/codesign --verify --deep --strict "$APP"
fi
if [[ "$RUN_SELF_TEST" == 1 ]]; then
  "$APP/Contents/MacOS/LumaLab" --self-test
fi
# Copy the signed bundle without extended attributes. Never re-sign in Documents.
rm -rf "$FINAL_APP"
/usr/bin/ditto --norsrc --noextattr --noqtn --noacl "$APP" "$FINAL_APP"
# A file provider can attach FinderInfo during the copy; clear only this generated app.
/usr/bin/xattr -cr "$FINAL_APP"
# The signed stage was strictly verified above. File-provider folders can
# attach root FinderInfo after copying. Verify every copied payload byte and
# symlink against that signed stage, independently of filesystem metadata.
/usr/bin/python3 - "$APP" "$FINAL_APP" <<'PYVERIFY'
import hashlib, pathlib, sys

def manifest(root):
    result = {}
    for path in pathlib.Path(root).rglob("*"):
        relative = str(path.relative_to(root))
        if path.is_symlink():
            result[relative] = ("link", str(path.readlink()))
        elif path.is_file():
            digest = hashlib.sha256()
            with path.open("rb") as stream:
                for data in iter(lambda: stream.read(1048576), b""):
                    digest.update(data)
            result[relative] = ("file", digest.hexdigest())
        else:
            result[relative] = ("directory", "")
    return result

if manifest(sys.argv[1]) != manifest(sys.argv[2]):
    raise SystemExit("Copied app differs from verified signed staging payload")
print("Copied app payload matches the strictly verified signed stage.")
PYVERIFY
if [[ "$MAKE_ZIP" == 1 ]]; then
  # Archive the clean staging app, before file-provider metadata can be added.
  /usr/bin/ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$APP" "$ROOT/dist/LumaLab-macOS-$ARCH.zip"
fi
printf '\nBuilt app: %s\nOpen with: open "%s"\n' "$FINAL_APP" "$FINAL_APP"
