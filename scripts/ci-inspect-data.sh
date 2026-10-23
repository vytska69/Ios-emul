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

dev=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$disk" | awk 'NR==1{print $1}')
echo "== attached $disk as $dev"
diskutil list | sed -n "/^\/dev\/disk/,\$p" | grep -A12 "synthesized" | head -40
data=$(diskutil list | awk '/APFS Volume Data /{print $NF}' | head -1)
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
