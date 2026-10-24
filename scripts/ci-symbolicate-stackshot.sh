#!/bin/bash
# Symbolicates the threads of chosen processes in the newest datamigrator stackshot on the emulated
# iPhone's Data volume, with the dyld shared cache from its System volume (macOS CI, after QEMU has
# stopped). Uses blacktop's `ipsw` tool.
#
#     scripts/ci-symbolicate-stackshot.sh vm/nvme.1 locationd [more process words]
set -u
disk=${1:?usage: ci-symbolicate-stackshot.sh nvme.1 words...}
shift
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)

bash "$here/ci-mount-volume.sh" "$disk" Data "
    ls \"\$MNT/mobile/Library/Logs/CrashReporter\"
    f=\$(ls -t \"\$MNT\"/mobile/Library/Logs/CrashReporter/stacks+*.ips 2>/dev/null | head -1)
    [ -n \"\$f\" ] && cp \"\$f\" '$work/stackshot.ips'
    find \"\$MNT/mobile/Library/Logs/CrashReporter/Panics\" \"\$MNT/mobile/Library/Logs/CrashReporter/Assistant\" -type f | head -10 | while read -r p; do
        echo \"---- \$p\"; head -c 3000 \"\$p\"; echo
    done
    chmod a+r '$work'/* 2>/dev/null"
[ -f "$work/stackshot.ips" ] || { echo "== no stackshot"; exit 0; }

bash "$here/ci-mount-volume.sh" "$disk" System "
    ls -la \"\$MNT/System/Library/Caches/com.apple.dyld/\"
    cp \"\$MNT\"/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e* '$work/'
    chmod a+r '$work'/*"
dsc=$(ls "$work"/dyld_shared_cache_arm64e 2>/dev/null)
[ -n "$dsc" ] || { echo "== no shared cache"; exit 0; }

# blacktop/ipsw from its latest GitHub release (the macOS universal build; needs GH_TOKEN).
ipsw=$(command -v ipsw)
if [ -z "$ipsw" ]; then
    mkdir -p "$work/ipsw"
    # Some releases carry only the ipswd daemon; use the newest one with the ipsw CLI.
    for tag in $(gh release list -R blacktop/ipsw -L 15 --json tagName -q '.[].tagName'); do
        gh release download "$tag" -R blacktop/ipsw --pattern 'ipsw_*_macOS_universal.tar.gz' -D "$work/ipsw" \
            >/dev/null 2>&1 && { echo "== ipsw $tag"; break; }
    done
    for t in "$work"/ipsw/*.tar.gz; do tar -xzf "$t" -C "$work/ipsw"; done
    # The archive also holds the ipswd daemon; take the binary that has the dyld commands.
    for candidate in $(find "$work/ipsw" -type f -perm -u+x); do
        if "$candidate" dyld --help >/dev/null 2>&1; then ipsw=$candidate; break; fi
    done
fi
[ -x "$ipsw" ] || { echo "== ipsw tool not available; release assets:"; gh release view -R blacktop/ipsw --json assets -q ".assets[].name" 2>&1 | head -20; exit 0; }

python3 "$here/stackshot-summary.py" "$work/stackshot.ips" "$@" --addresses > "$work/summary.txt"
grep -o '@0x[0-9a-f]*' "$work/summary.txt" | tr -d @ | sort -u | head -150 > "$work/addrs.txt"
echo "== $(wc -l < "$work/addrs.txt") shared-cache addresses; ipsw $("$ipsw" version 2>&1 | head -1)"
"$ipsw" dyld a2s "$dsc" "$(head -1 "$work/addrs.txt")" 2>&1 | head -20
while read -r a; do
    # ipsw logs its answer on stderr; keep the last lines, without colour codes.
    sym=$("$ipsw" dyld a2s "$dsc" "$a" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -v '^[[:space:]]*$' | tail -2 | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-220)
    echo "$a $sym"
done < "$work/addrs.txt" > "$work/symbols.txt"
python3 - "$work/summary.txt" "$work/symbols.txt" <<'EOF'
import re, sys
syms = {}
for line in open(sys.argv[2]):
    parts = line.split(" ", 1)
    syms[parts[0]] = parts[1].strip() if len(parts) > 1 else ""
for line in open(sys.argv[1]):
    m = re.search(r"@(0x[0-9a-f]+)", line)
    print(line.rstrip() + ("   " + syms.get(m.group(1), "") if m else ""))
EOF
