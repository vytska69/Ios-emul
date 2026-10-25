#!/bin/bash
# Disassembles the kernelcache around kernel addresses, e.g. a panic's pc and lr (macOS CI). The
# machine boots with kaslr-off, so panic addresses are the kernelcache's own.
#
#     scripts/ci-kernel-disass.sh vm/firmware/kernelcache.release.n104 0xfffffff009772468 [...]
#
# COUNT instructions are shown from 0x40 bytes before each address (default 48).
set -u
kc=${1:?usage: ci-kernel-disass.sh kernelcache address...}
shift
work=$(mktemp -d)
mkdir -p "$work/ipsw"
for tag in $(gh release list -R blacktop/ipsw -L 15 --json tagName -q '.[].tagName'); do
    gh release download "$tag" -R blacktop/ipsw --pattern 'ipsw_*_macOS_universal.tar.gz' -D "$work/ipsw" \
        >/dev/null 2>&1 && break
done
for t in "$work"/ipsw/*.tar.gz; do tar -xzf "$t" -C "$work/ipsw"; done
ipsw=
for candidate in $(find "$work/ipsw" -type f -perm -u+x); do
    if "$candidate" kernel --help >/dev/null 2>&1; then ipsw=$candidate; break; fi
done
[ -n "$ipsw" ] || { echo "== ipsw tool not available"; exit 0; }

"$ipsw" kernel dec "$kc" -o "$work/dec" >/dev/null 2>&1
macho=$(find "$work/dec" -type f | head -1)
[ -n "$macho" ] || macho=$kc
for addr in "$@"; do
    start=$(printf '0x%x' $(( addr - 0x40 )))
    echo "==== $addr"
    "$ipsw" macho info "$macho" --fileset-entry-for "$addr" 2>/dev/null | head -3
    "$ipsw" macho disass "$macho" --vaddr "$start" --count "${COUNT:-48}" 2>&1 | head -"${COUNT:-48}"
done
