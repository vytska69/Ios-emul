#!/bin/bash
# Mounts the emulated iPhone's Data volume (macOS only, after QEMU has stopped) and prints what iOS
# left there: crash reports, and the files under /private/var/log and /private/var/logs.
#
#     scripts/ci-inspect-data.sh vm/nvme.1 [extra path under /private/var ...]
#
# Works for the direct-install Data volume, which is not encrypted.
set -u
disk=${1:?usage: ci-inspect-data.sh nvme.1 [paths]}
shift

# The namespace has 4 KiB blocks, so macOS (512-byte sectors) does not see its GPT. Attach just the
# APFS container: find its superblock ("NXSB" at byte 32 of a block) in the first 16 MiB.
offset=$(python3 -c '
import sys
f = open(sys.argv[1], "rb")
for o in range(0, 16 << 20, 4096):
    f.seek(o + 32)
    if f.read(4) == b"NXSB":
        print(o); break
' "$disk")
[ -n "$offset" ] || { echo "== no APFS container in $disk"; exit 0; }
echo "== APFS container at byte $offset"
image=$disk
if ! dev=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount -section "$((offset / 512))" "$disk" 2>/dev/null | awk 'NR==1{print $1}') || [ -z "$dev" ]; then
    image=$(mktemp -d)/container.img
    dd if="$disk" of="$image" bs=1m skip=$((offset >> 20)) conv=sparse 2>/dev/null
    dev=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$image" | awk 'NR==1{print $1}')
fi
echo "== attached as $dev"
sleep 2
# Only the container whose physical store is the attached image, never the runner's own disks.
container=$(diskutil list | awk -v store="${dev#/dev/}" '
    /^\/dev\/disk[0-9]+ \(synthesized\)/ { cur = $1 }
    /Physical Store/ && $NF ~ "^" store "(s[0-9]+)?$" { print cur; exit }')
echo "== container ${container:-not found}"
[ -n "$container" ] && diskutil list "$container"
data=$([ -n "$container" ] && diskutil list "$container" | awk '/APFS Volume Data /{print $NF}' | head -1)
mnt=$(mktemp -d)
if [ -z "$data" ] || ! sudo mount -t apfs -o rdonly "/dev/$data" "$mnt"; then
    echo "== could not mount the Data volume (${data:-not found})"
    hdiutil detach "$dev" >/dev/null 2>&1
    exit 0
fi
echo "== Data volume /dev/$data mounted at $mnt"

echo "== crash reports"
sudo find "$mnt/mobile/Library/Logs/CrashReporter" -type f 2>/dev/null | head -80
for f in $(sudo find "$mnt/mobile/Library/Logs/CrashReporter" -type f \( -name '*.ips' -o -name '*.crash' \) 2>/dev/null | head -40); do
    echo "---- $f"
    sudo head -c 2500 "$f"; echo
done

echo "== log files"
sudo find "$mnt/log" "$mnt/logs" -type f 2>/dev/null | head -60
for f in $(sudo find "$mnt/log" "$mnt/logs" -type f -size -2000k 2>/dev/null | grep -v '\.tracev3$' | head -20); do
    echo "---- $f"
    sudo tail -c 3000 "$f" | strings | tail -40
done

for p in "$@"; do
    echo "== $p"
    sudo ls -la "$mnt/$p" 2>&1 | head -60
done

sudo umount "$mnt"
hdiutil detach "$dev" >/dev/null 2>&1
