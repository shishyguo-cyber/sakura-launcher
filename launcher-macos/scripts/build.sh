#!/bin/bash
# Builds Sakura.app (release) into the work folder and links it at launcher-macos/build/Sakura.app.
#   GARDENBOOT_WORK_ROOT  where intermediate files and the app go (default: ~/Library/Caches/GardenBoot)
#   SAKURA_UNIVERSAL=1    also build for Intel and ship one universal binary
# The app is signed ad hoc only; that is enough for local use, not for distribution without Gatekeeper prompts.
set -euo pipefail

package_dir="$(cd "$(dirname "$0")/.." && pwd)"
work="${GARDENBOOT_WORK_ROOT:-$HOME/Library/Caches/GardenBoot}"
mkdir -p "$work"
work="$(cd "$work" && pwd)"
export CLANG_MODULE_CACHE_PATH="$work/swift-modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"

# One SwiftPM invocation shape for every build. The native build system is used because the newer one could
# not start dsymutil inside some execution sandboxes; this flag does not change any outer sandbox.
swiftpm() {
  local scratch="$1"; shift
  swift build --disable-sandbox --build-system native \
    --cache-path "$work/swiftpm/cache" --config-path "$work/swiftpm/config" --security-path "$work/swiftpm/security" \
    --package-path "$package_dir" --scratch-path "$scratch" -c release "$@"
}

swiftpm "$work/swift-build"
host_binary="$(swiftpm "$work/swift-build" --show-bin-path)/GardenBoot"

bundle="$work/products/Sakura.app"
contents="$bundle/Contents"
mkdir -p "$contents/MacOS"
if [ "${SAKURA_UNIVERSAL:-0}" = "1" ]; then
  intel_scratch="$work/swift-build-x86_64"
  swiftpm "$intel_scratch" --triple x86_64-apple-macosx13.0
  intel_binary="$(swiftpm "$intel_scratch" --triple x86_64-apple-macosx13.0 --show-bin-path)/GardenBoot"
  lipo -create "$host_binary" "$intel_binary" -output "$contents/MacOS/GardenBoot"
else
  cp "$host_binary" "$contents/MacOS/GardenBoot"
fi
cp "$package_dir/Resources/Info.plist" "$contents/Info.plist"

# Resources are ours alone: rebuild them from scratch so a removed file cannot linger in the bundle.
rm -rf "${contents:?}/Resources"
mkdir -p "$contents/Resources"
cp -R "$package_dir/demo-pack" "$contents/Resources/demo-pack"
if [ -d "$package_dir/featured-pack" ]; then
  mkdir -p "$contents/Resources/featured-pack"
  for file in manifest.json NOTICE.md intro.mp4 loop.mov outro.mp4; do
    cp "$package_dir/featured-pack/$file" "$contents/Resources/featured-pack/$file"
  done
fi

xattr -cr "$bundle"
codesign --force --sign - --identifier local.gardenboot.GardenBoot "$bundle"
codesign --verify --deep --strict "$bundle"

# Stable path for scripts and docs. Only replace our own generated link or folder.
# SAKURA_NO_LINK=1 (used by package.sh) leaves the development link pointing at the everyday build.
if [ "${SAKURA_NO_LINK:-0}" = "1" ]; then echo "$bundle"; exit 0; fi
link="$package_dir/build/Sakura.app"
mkdir -p "$(dirname "$link")"
if [ -L "$link" ]; then rm "$link"; elif [ -d "$link" ]; then rm -rf "${link:?}"; fi
ln -s "$bundle" "$link"

echo "$bundle"
