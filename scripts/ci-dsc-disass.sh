#!/bin/bash
# Disassembles functions from the emulated iPhone's dyld shared cache (macOS CI): copies the cache
# off the System volume and runs blacktop's `ipsw dyld disass` on each symbol.
#
#     scripts/ci-dsc-disass.sh vm/nvme.1 _MKBDeviceUnlockedSinceBoot ...
set -u
disk=${1:?usage: ci-dsc-disass.sh nvme.1 symbols...}
shift
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)

bash "$here/ci-mount-volume.sh" "$disk" System "
    cp \"\$MNT\"/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e* '$work/'
    chmod a+r '$work'/*" >/dev/null
dsc=$work/dyld_shared_cache_arm64e
[ -f "$dsc" ] || { echo "== no shared cache"; exit 0; }

mkdir -p "$work/ipsw"
for tag in $(gh release list -R blacktop/ipsw -L 15 --json tagName -q '.[].tagName'); do
    gh release download "$tag" -R blacktop/ipsw --pattern 'ipsw_*_macOS_universal.tar.gz' -D "$work/ipsw" \
        >/dev/null 2>&1 && break
done
for t in "$work"/ipsw/*.tar.gz; do tar -xzf "$t" -C "$work/ipsw"; done
ipsw=
for candidate in $(find "$work/ipsw" -type f -perm -u+x); do
    if "$candidate" dyld --help >/dev/null 2>&1; then ipsw=$candidate; break; fi
done
[ -n "$ipsw" ] || { echo "== ipsw tool not available"; exit 0; }

for sym in "$@"; do
    echo "==== $sym"
    "$ipsw" dyld disass "$dsc" --symbol "$sym" --symbolicate 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -v 'failed to parse objc' | head -160
done
