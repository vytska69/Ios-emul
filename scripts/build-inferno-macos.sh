#!/bin/bash
# Builds the Inferno QEMU fork for macOS with this repo's patches into a prefix, for boot tests.
#
#   scripts/build-inferno-macos.sh <inferno revision> <install prefix> [--tci]
#
# --tci builds the TCG interpreter, as the iOS app runs without JIT (qemu-aarch64-softmmu-tci).
# Same pinned revision and patches as the iOS build (scripts/build-qemu-ios.sh).
set -euo pipefail
rev="$1"
prefix="$2"
tci=()
[ "${3:-}" = --tci ] && tci=(--enable-tcg-interpreter)
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"

brew install meson ninja pkg-config glib pixman nettle libtasn1 lzfse gnutls libslirp
git init -q "$work/inferno"
git -C "$work/inferno" fetch -q --depth 1 https://github.com/ChefKissInc/QEMUAppleSilicon.git "$rev"
git -C "$work/inferno" checkout -q FETCH_HEAD
git -C "$work/inferno" submodule update --init --depth 1 util/mlib
for p in "$root"/qemu/patches/inferno/*.patch; do git -C "$work/inferno" apply --whitespace=nowarn "$p"; done
mkdir "$work/inferno/build" && cd "$work/inferno/build"
../configure --prefix="$prefix" \
  --target-list=aarch64-softmmu --disable-werror --enable-lzfse --enable-slirp --disable-gcrypt --enable-nettle \
  --extra-cflags="-I$(brew --prefix)/include" --extra-ldflags="-L$(brew --prefix)/lib" ${tci[@]+"${tci[@]}"}
ninja
# A full install puts QEMU's data files (VNC keymaps, firmware) in <prefix>/share/qemu,
# where the relocatable binary in <prefix>/bin looks for them.
meson install --quiet
ls "$prefix/bin" "$prefix/share/qemu" | head -20
