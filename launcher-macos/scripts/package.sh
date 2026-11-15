#!/bin/bash
# Release build of Sakura.app for distribution: universal (Apple silicon + Intel), debug info stripped, ad-hoc signed.
#   bash launcher-macos/scripts/package.sh [work folder]
# Default work folder: ~/Library/Caches/Sakura-release (kept apart from the everyday development build).
# Prints the path of the finished Sakura.app; hand it to scripts/package-release.py --mac-app.
#
# Why strip: release binaries otherwise keep debug paths such as the builder's home folder.
# Why not Documents/iCloud: File Provider can add attributes to a .app there, which breaks signature checks.
set -euo pipefail

package_dir="$(cd "$(dirname "$0")/.." && pwd)"
work="${1:-$HOME/Library/Caches/Sakura-release}"
mkdir -p "$work"
work="$(cd "$work" && pwd)"

built="$(GARDENBOOT_WORK_ROOT="$work" SAKURA_UNIVERSAL=1 SAKURA_NO_LINK=1 bash "$package_dir/scripts/build.sh" | tail -n 1)"

release="$work/release/Sakura.app"
rm -rf "${work:?}/release"
mkdir -p "$work/release"
ditto --norsrc --noextattr "$built" "$release"

binary="$release/Contents/MacOS/GardenBoot"
xcrun strip -S "$binary"
xattr -cr "$release"
codesign --force --sign - --identifier local.gardenboot.GardenBoot "$release"
codesign --verify --deep --strict "$release"

archs="$(lipo -archs "$binary")"
case "$archs" in
  *arm64*x86_64*|*x86_64*arm64*) ;;
  *) echo "expected a universal binary, got: $archs" >&2; exit 1 ;;
esac
if LC_ALL=C grep -q -a -E '/Users/[A-Za-z0-9_.-]+/' "$binary"; then
  echo "the stripped binary still contains a home-folder path" >&2; exit 1
fi

echo "$release"
