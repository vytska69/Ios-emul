#!/usr/bin/env bash
# Builds the Inferno QEMU fork for iOS (arm64) as qemu-aarch64-softmmu.framework plus its
# dependency frameworks, into App/Frameworks — the layout QEMURunner dlopen()s on iOS.
#
#   scripts/build-qemu-ios.sh [--tci]
#
# Requirements: macOS with Xcode and Homebrew
#   brew install meson ninja pkg-config glib gettext libgpg-error bison python-setuptools
#   pip3 install six pyparsing
#
# How it works:
#   1. Inferno is cloned at a pinned revision and qemu/patches/inferno/*.patch are applied. They add
#      what iOS needs: a shared-library build exporting qemu_init/qemu_main_loop/qemu_cleanup
#      (iOS apps cannot spawn processes) and the libucontext coroutine backend.
#   2. UTM's build_dependencies.sh cross-compiles glib, pixman, … and then QEMU itself (-q). A copy
#      of it is adjusted to drop UTM-only configure flags, build only the targets we use, and also
#      build the libraries Inferno needs beyond UTM's set (nettle ≥ 3.10, libtasn1, lzfse).
#   3. UTM's fixup step turns every dylib into a framework; they are copied to App/Frameworks.
#
# --tci builds the TCG interpreter instead of the JIT: much slower, but runs without a JIT
# entitlement or debugger attached (the same trade-off as UTM SE).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build-qemu"
OUT="$ROOT/App/Frameworks"
UTM_TAG="v5.0.8"
INFERNO_URL="https://github.com/ChefKissInc/QEMUAppleSilicon.git"
INFERNO_REV="${INFERNO_REV:-cc4302a99167abec69b714cfd00c38caece7e7de}"
NETTLE_SRC="https://ftp.gnu.org/gnu/nettle/nettle-3.10.1.tar.gz"
TASN1_SRC="https://ftp.gnu.org/gnu/libtasn1/libtasn1-4.20.0.tar.gz"
LZFSE_SRC="https://github.com/lzfse/lzfse/archive/refs/tags/lzfse-1.0.tar.gz"
PLATFORM="ios"

while [ $# -gt 0 ]; do
  case "$1" in
    --tci) PLATFORM="ios-tci" ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$WORK" "$OUT"

# --- 1. patched Inferno ----------------------------------------------------------------------
SRC="$WORK/inferno"
if [ ! -d "$SRC" ]; then
  git init -q "$SRC"
  git -C "$SRC" fetch -q --depth 1 "$INFERNO_URL" "$INFERNO_REV"
  git -C "$SRC" checkout -q FETCH_HEAD
  git -C "$SRC" submodule update --init --depth 1 util/mlib
  for p in "$ROOT"/qemu/patches/inferno/*.patch; do
    echo "==> applying $(basename "$p")"
    git -C "$SRC" apply --whitespace=nowarn "$p"
  done
fi

# --- 2. UTM dependency build, adjusted ---------------------------------------------------------
if [ ! -d "$WORK/UTM" ]; then
  git clone -q --depth 1 --branch "$UTM_TAG" https://github.com/utmapp/UTM.git "$WORK/UTM"
fi

EXTRA="$WORK/extra-src"
mkdir -p "$EXTRA"
fetch() {
  local url="$1" dir="$EXTRA/$2"
  [ -d "$dir" ] || curl -fsSL --retry 3 "$url" | tar -xz -C "$EXTRA"
  [ -d "$dir" ] || { echo "error: $url did not unpack to $dir" >&2; exit 1; }
}
fetch "$NETTLE_SRC" nettle-3.10.1
fetch "$TASN1_SRC" libtasn1-4.20.0
fetch "$LZFSE_SRC" lzfse-lzfse-1.0

SCRIPT="$WORK/UTM/scripts/build_dependencies_inferno.sh"
python3 - "$WORK/UTM/scripts/build_dependencies.sh" "$SCRIPT" "$EXTRA" <<'EOF'
import re
import sys
src, dst, extra = sys.argv[1:]
s = open(src).read()

def sub(old, new):
    global s
    if old not in s:
        sys.exit(f"UTM script changed; cannot find: {old!r}")
    s = s.replace(old, new)

def resub(pattern, new):
    global s
    s, n = re.subn(pattern, lambda _: new, s, flags=re.M)
    if n == 0:
        sys.exit(f"UTM script changed; cannot find: {pattern!r}")

# UTM-only configure flags that Inferno does not have.
sub('HVF_FLAGS="--enable-hvf-private"', 'HVF_FLAGS="--disable-hvf"')
resub(r'TCI_BUILD_FLAGS="--enable-tcg-threaded-interpreter[^"]*"', 'TCI_BUILD_FLAGS="--enable-tcg-interpreter"')
# Only the Apple machines' target, Inferno's crypto backend, no extras we never use.
sub('--enable-ucontext --with-coroutine=libucontext $HVF_FLAGS $TCI_BUILD_FLAGS"',
    '--enable-ucontext --with-coroutine=libucontext --target-list=aarch64-softmmu --disable-gcrypt --enable-nettle '
    '--enable-lzfse --disable-spice --disable-usb-redir --disable-libusb --disable-tools $HVF_FLAGS $TCI_BUILD_FLAGS"')
# Extra libraries Inferno links against, built with the same toolchain before QEMU.
resub(r'^build \$QEMU_DIR --cross-prefix="" \$QEMU_PLATFORM_BUILD_FLAGS.*$',
    # Not via UTM's build(): for a directory argument it forgets to shift, passing the path to configure.
    f'(cd "{extra}/nettle-3.10.1" && ./configure --prefix="$PREFIX" --host="$CHOST" --disable-documentation '
    f'--disable-assembler --enable-mini-gmp --disable-shared && make -j$NCPU && make install)\n'
    f'(cd "{extra}/libtasn1-4.20.0" && ./configure --prefix="$PREFIX" --host="$CHOST" --disable-doc '
    f'--disable-shared && make -j$NCPU && make install)\n'
    f'(cd "{extra}/lzfse-lzfse-1.0" && make clean >/dev/null 2>&1 || true; '
    f'make CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" INSTALL_PREFIX="$PREFIX" install)\n'
    'build $QEMU_DIR --cross-prefix="" $QEMU_PLATFORM_BUILD_FLAGS $QEMU_DEBUG_FLAGS')
# UTM's own UI and GPU stacks (SPICE client, ANGLE, Mesa, Vulkan, virgl, D3D) and its iOS
# hypervisor shim: we display through VNC and run TCG, so none of it is needed.
sub('\nbuild_spice_client\n', '\n')
sub('\nbuild_vulkan_drivers\n', '\n')
sub('\nbuild_d3d_drivers\n', '\n')
resub(r'^    # GPU support\n(?:.*\n)*?(?=    # Hypervisor for iOS)', '')
resub(r'^    # Hypervisor for iOS\n    if .*\n        build_hypervisor\n    fi\n', '')
for repo in ("WEBKIT", "EPOXY", "VULKAN_LOADER", "VIRGLRENDERER", "HYPERVISOR", "MESA", "MOLTENVK", "DXMT", "D3DMETAL"):
    resub(rf'^    clone \${repo}_REPO .*\n', '')
resub(r'^    clone_moltenvk_dependences .*\n', '')
resub(r'^    download \$LLVM15_SRC\n', '')
for formula in ("llvm", "spirv-llvm-translator", "libxcb", "libxrandr"):
    resub(rf"^    brew --prefix {re.escape(formula)} .*\n", '')
open(dst, "w").write(s)
EOF
chmod +x "$SCRIPT"

echo "==> Building dependencies and Inferno for $PLATFORM (this takes a while)"
(cd "$WORK/UTM" && "$SCRIPT" -p "$PLATFORM" -a arm64 -q "$SRC")

# --- 3. frameworks -----------------------------------------------------------------------------
case "$PLATFORM" in
  ios) SYSROOT="$WORK/UTM/sysroot-iOS-arm64" ;;
  ios-tci) SYSROOT="$WORK/UTM/sysroot-iOS-TCI-arm64" ;;
esac
[ -d "$SYSROOT/Frameworks/qemu-aarch64-softmmu.framework" ] || {
  echo "error: qemu-aarch64-softmmu.framework was not produced" >&2; exit 1; }
nm -gU "$SYSROOT/Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu" | grep -q _qemu_main_loop || {
  echo "error: QEMU framework does not export qemu_main_loop" >&2; exit 1; }
rsync -a --delete "$SYSROOT/Frameworks/" "$OUT/"
# Data files QEMU loads at runtime (VNC keymaps, firmware); QEMURunner passes them with -L.
if [ -d "$SYSROOT/share/qemu" ]; then
  rsync -a --delete "$SYSROOT/share/qemu/" "$ROOT/App/QEMUData/"
fi
echo "Done: $(ls "$OUT" | wc -l | tr -d ' ') frameworks in App/Frameworks. Now run 'xcodegen generate'."
