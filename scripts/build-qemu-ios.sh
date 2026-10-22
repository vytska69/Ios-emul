#!/usr/bin/env bash
# Cross-compiles the QEMU forks used by EmulatorKit's backends for iOS (arm64) and packages each
# qemu-system-* binary as a framework in App/Frameworks, the layout QEMURunner dlopen()s on iOS.
#
#   scripts/build-qemu-ios.sh [--tci] [--only inferno|ipod2g|ipod1g]
#
# Requirements: macOS with Xcode, Homebrew (meson ninja pkg-config glib gettext).
#
# Stages:
#   1. Dependencies (glib, pixman, libffi, gettext, …) for iOS are built with UTM's battle-tested
#      build_dependencies.sh, which already solves the iOS cross-compilation quirks.
#   2. Each QEMU fork is configured against that sysroot and built.
#   3. The qemu-system-* link step is replayed with -dynamiclib so qemu_init / qemu_main_loop /
#      qemu_cleanup are callable in-process (iOS apps cannot spawn processes).
#
# --tci builds the TCG interpreter instead of the JIT: roughly 5-10x slower, but works without
# a JIT entitlement or debugger attached (same trade-off as UTM SE).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build-qemu"
OUT="$ROOT/App/Frameworks"
UTM_TAG="v4.6.4"
TCI=0
ONLY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --tci) TCI=1 ;;
    --only) ONLY="$2"; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

# name | git url | branch | target | binary | framework (must match QEMURunner's naming)
FORKS=(
  "inferno|https://github.com/ChefKissInc/QEMUAppleSilicon.git|master|aarch64-softmmu|qemu-system-aarch64|qemu-aarch64-softmmu"
  "ipod2g|https://github.com/devos50/qemu-ios.git|ipod_touch_2g|arm-softmmu|qemu-system-arm|qemu-arm-softmmu"
  "ipod1g|https://github.com/devos50/qemu-ios.git|ipod_touch_1g|arm-softmmu|qemu-system-arm|qemu-arm-1g-softmmu"
)

mkdir -p "$WORK" "$OUT"

# --- 1. dependencies -------------------------------------------------------------------------
if [ ! -d "$WORK/UTM" ]; then
  git clone --depth 1 --branch "$UTM_TAG" https://github.com/utmapp/UTM.git "$WORK/UTM"
fi
SYSROOT="$WORK/UTM/sysroot-ios-arm64"
if [ ! -f "$SYSROOT/lib/libglib-2.0.dylib" ] && [ ! -f "$SYSROOT/lib/libglib-2.0.a" ]; then
  echo "==> Building iOS dependencies with UTM (this takes a while)"
  (cd "$WORK/UTM" && ./scripts/build_dependencies.sh -p ios -a arm64)
fi

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="$(xcrun --sdk iphoneos -f clang)"
CFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=16.0 -I$SYSROOT/include"
LDFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=16.0 -L$SYSROOT/lib"
export PKG_CONFIG_PATH="$SYSROOT/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"

# Meson cross file so QEMU's configure treats this as an iOS/darwin host.
CROSS="$WORK/ios-arm64.meson"
cat > "$CROSS" <<EOF
[binaries]
c = ['$CC', '-arch', 'arm64', '-isysroot', '$SDK']
objc = ['$CC', '-arch', 'arm64', '-isysroot', '$SDK']
ar = '$(xcrun --sdk iphoneos -f ar)'
strip = '$(xcrun --sdk iphoneos -f strip)'
pkg-config = 'pkg-config'

[host_machine]
system = 'darwin'
subsystem = 'ios'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
EOF

# --- 2./3. QEMU forks ------------------------------------------------------------------------
for spec in "${FORKS[@]}"; do
  IFS='|' read -r name url branch target binary fwname <<<"$spec"
  [ -n "$ONLY" ] && [ "$ONLY" != "$name" ] && continue
  src="$WORK/qemu-$name"
  [ -d "$src" ] || git clone --depth 1 --branch "$branch" --recurse-submodules "$url" "$src"

  build="$src/build-ios"
  mkdir -p "$build"
  echo "==> Configuring $name ($target)"
  extra=()
  [ "$TCI" = 1 ] && extra+=(--enable-tcg-interpreter)
  (cd "$build" && ../configure \
      --target-list="$target" \
      --cross-prefix="" \
      --extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS" \
      --cross-file="$CROSS" \
      --disable-cocoa --disable-sdl --disable-gtk --disable-opengl --disable-hvf \
      --disable-tools --disable-docs --disable-guest-agent --disable-slirp-smbd \
      --enable-vnc --disable-vnc-sasl --disable-vnc-jpeg \
      --without-default-features --enable-pie \
      "${extra[@]}")

  echo "==> Building $name"
  ninja -C "$build" "$binary"

  # Replay the executable's link line as a dylib. ninja -t commands prints it verbatim.
  link="$(ninja -C "$build" -t commands "$binary" | tail -n 1)"
  fw="$OUT/$fwname.framework"
  mkdir -p "$fw"
  dylib_link="${link/ -o $binary / -o $fw/$fwname }"
  dylib_link="$dylib_link -dynamiclib -install_name @rpath/$fwname.framework/$fwname"
  (cd "$build" && eval "$dylib_link")

  cat > "$fw/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$fwname</string>
  <key>CFBundleIdentifier</key><string>com.iosemul.$fwname</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>16.0</string>
</dict></plist>
EOF
  nm -gU "$fw/$fwname" | grep -q "_qemu_main_loop" || { echo "error: $fwname does not export qemu_main_loop" >&2; exit 1; }
  echo "==> $fw"
done

# Dependency dylibs from the UTM sysroot must ship alongside QEMU.
for lib in "$SYSROOT"/Frameworks/*.framework; do
  [ -e "$lib" ] && rsync -a "$lib" "$OUT/"
done
echo "Done. Regenerate the project with 'xcodegen generate' and build in Xcode."
