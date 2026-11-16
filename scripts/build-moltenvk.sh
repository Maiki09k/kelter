#!/bin/zsh

# Builds Kelter's MoltenVK for id Tech games (DOOM Eternal) into Resources/libMoltenVK-kelter.dylib:
# official MoltenVK v1.4.2 from KhronosGroup plus shim/moltenvk-idtech.patch (see MoltenVK issue #2818)
# and SPIRV-Cross with shim/spirv-cross-double-as-float.patch (Metal has no double; DOOM Eternal uses it).
# Needs Xcode and cmake (brew install cmake). First run fetches about 500 MB of dependencies and
# takes 20 to 40 minutes; later runs only rebuild MoltenVK.

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
SOURCE="$PROJECT_DIR/.toolchain/MoltenVK"
PATCH="$PROJECT_DIR/shim/moltenvk-idtech.patch"
SPIRV_CROSS="$PROJECT_DIR/.toolchain/SPIRV-Cross-kelter"
SPIRV_PATCH="$PROJECT_DIR/shim/spirv-cross-double-as-float.patch"
OUT="$PROJECT_DIR/Resources/libMoltenVK-kelter.dylib"

if [[ ! -d "$SOURCE" ]]; then
  git clone --depth 1 --branch v1.4.2 https://github.com/KhronosGroup/MoltenVK.git "$SOURCE"
fi
cd "$SOURCE"
if ! git apply --reverse --check "$PATCH" 2>/dev/null; then
  git apply "$PATCH"
fi

# fetchDependencies resets its own SPIRV-Cross checkout, so the patched copy lives next to it.
if [[ ! -d "$SPIRV_CROSS" ]]; then
  git clone https://github.com/KhronosGroup/SPIRV-Cross.git "$SPIRV_CROSS"
  git -C "$SPIRV_CROSS" checkout "$(cat ExternalRevisions/SPIRV-Cross_repo_revision)"
fi
if ! git -C "$SPIRV_CROSS" apply --reverse --check "$SPIRV_PATCH" 2>/dev/null; then
  git -C "$SPIRV_CROSS" apply "$SPIRV_PATCH"
fi
STAMP="External/build/.kelter-spirv-cross"
WANTED="$(shasum -a 256 "$SPIRV_PATCH" | cut -d' ' -f1)"
if [[ ! -d External/build || "$(cat "$STAMP" 2>/dev/null)" != "$WANTED" ]]; then
  ./fetchDependencies --macos --spirv-cross-root "$SPIRV_CROSS"
  echo "$WANTED" > "$STAMP"
fi
make macos

BUILT="$SOURCE/Package/Release/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib"
cp "$BUILT" "$OUT"
# Wine runs as x86_64 under Rosetta, so the library must contain that slice.
lipo -info "$OUT"
echo "$OUT"
