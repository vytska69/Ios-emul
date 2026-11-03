#!/bin/bash
# Puts QEMU (built by scripts/build-inferno-macos.sh) into the Mac app as a helper process, with
# the Homebrew libraries it links copied into Contents/Frameworks, then signs everything ad hoc.
#
#   scripts/bundle-qemu-macos.sh "path/to/iOS Emul.app" <qemu prefix>
#
# QEMU's data files go to Contents/Resources/qemu (the app passes -L). The helper gets the
# Hypervisor.framework entitlement (App/Mac/qemu.entitlements) for -accel hvf.
set -euo pipefail
app="$1"
prefix="$2"
root="$(cd "$(dirname "$0")/.." && pwd)"
macos="$app/Contents/MacOS"
frameworks="$app/Contents/Frameworks"
mkdir -p "$macos" "$frameworks" "$app/Contents/Resources"
cp "$prefix/bin/qemu-system-aarch64" "$macos/"
chmod u+w "$macos/qemu-system-aarch64"
rm -rf "$app/Contents/Resources/qemu"
cp -R "$prefix/share/qemu" "$app/Contents/Resources/qemu"
# Every non-system library, recursively, rewritten to @executable_path/../Frameworks.
dylibbundler -cd -of -b -x "$macos/qemu-system-aarch64" -d "$frameworks/" -p @executable_path/../Frameworks/
otool -L "$macos/qemu-system-aarch64" | grep -v -E '^\s*(/usr/lib|/System)' || true
for lib in "$frameworks"/*.dylib; do
  [ -e "$lib" ] && codesign --force --sign - "$lib"
done
codesign --force --sign - --entitlements "$root/App/Mac/qemu.entitlements" "$macos/qemu-system-aarch64"
codesign --force --sign - --entitlements "$root/App/Mac/qemu.entitlements" "$app"
codesign --verify --verbose "$app"
