#!/bin/bash
# Mounts one APFS volume of the emulated iPhone's disk read-only (macOS only, after QEMU has
# stopped) and runs a shell command with $MNT set to its mount point.
#
#     scripts/ci-mount-volume.sh vm/nvme.1 Data 'ls "$MNT/mobile"'
#     scripts/ci-mount-volume.sh vm/nvme.1 System 'strings "$MNT/usr/libexec/datamigrator"'
#
# "System" matches the IPSW's system volume (named after the build, e.g. Azul18A373...).
set -u
disk=${1:?usage: ci-mount-volume.sh nvme.1 volume command}
volume=${2:?volume name}
command=${3:?command}

# 4 KiB blocks: macOS does not see the GPT, so attach just the APFS container.
offset=$(python3 -c '
import sys
f = open(sys.argv[1], "rb")
for o in range(0, 16 << 20, 4096):
    f.seek(o + 32)
    if f.read(4) == b"NXSB":
        print(o); break
' "$disk")
[ -n "$offset" ] || { echo "== no APFS container in $disk"; exit 0; }
dev=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount -section "$((offset / 512))" "$disk" | awk 'NR==1{print $1}')
sleep 2
container=$(diskutil list | awk -v store="${dev#/dev/}" '
    /^\/dev\/disk[0-9]+ \(synthesized\)/ { cur = $1 }
    /Physical Store/ && $NF ~ "^" store "(s[0-9]+)?$" { print cur; exit }')
[ -n "$container" ] || { echo "== no APFS container attached"; hdiutil detach "$dev" >/dev/null 2>&1; exit 0; }
if [ "$volume" = System ]; then
    node=$(diskutil list "$container" | awk '/APFS Volume / && $0 !~ /Preboot|xART|Data|Update|Hardware|Baseband/ {print $NF; exit}')
else
    node=$(diskutil list "$container" | awk -v v="$volume" '$0 ~ "APFS Volume " v " " {print $NF; exit}')
fi
MNT=$(mktemp -d)
if [ -z "$node" ] || ! sudo mount -t apfs -o rdonly "/dev/$node" "$MNT"; then
    echo "== could not mount $volume (${node:-not found})"
else
    echo "== $volume (/dev/$node) at $MNT"
    export MNT
    sudo -E bash -c "$command"
    sudo umount "$MNT"
fi
hdiutil detach "$dev" >/dev/null 2>&1
