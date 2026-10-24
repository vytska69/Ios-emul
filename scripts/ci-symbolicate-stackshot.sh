#!/bin/bash
# Symbolicates the threads of chosen processes in the newest datamigrator stackshot on the emulated
# iPhone's Data volume, with the dyld shared cache from its System volume (macOS CI, after QEMU has
# stopped). Uses blacktop's `ipsw` tool.
#
#     [CRASH=CommCenter] scripts/ci-symbolicate-stackshot.sh vm/nvme.1 locationd [more process words]
set -u
disk=${1:?usage: ci-symbolicate-stackshot.sh nvme.1 words...}
shift
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)

bash "$here/ci-mount-volume.sh" "$disk" Data "
    ls \"\$MNT/mobile/Library/Logs/CrashReporter\"
    f=\$(ls -t \"\$MNT\"/mobile/Library/Logs/CrashReporter/stacks+*.ips 2>/dev/null | head -1)
    [ -n \"\$f\" ] && cp \"\$f\" '$work/stackshot.ips'
    c=\$(ls -t \"\$MNT\"/mobile/Library/Logs/CrashReporter/${CRASH:-none}-*.ips 2>/dev/null | head -1)
    [ -n \"\$c\" ] && cp \"\$c\" '$work/crash.ips'
    find \"\$MNT/mobile/Library/Logs/CrashReporter/Panics\" \"\$MNT/mobile/Library/Logs/CrashReporter/Assistant\" -type f | head -10 | while read -r p; do
        echo \"---- \$p\"; head -c 3000 \"\$p\"; echo
    done
    chmod a+r '$work'/* 2>/dev/null"
[ -f "$work/stackshot.ips" ] || [ -f "$work/crash.ips" ] || { echo "== no stackshot or crash report"; exit 0; }

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

# With CRASH=<process>, also the newest crash report of that process, symbolicated by ipsw.
if [ -f "$work/crash.ips" ]; then
    echo "== crash report"
    # iOS 14 reports are text after a one-line JSON header; show the lines that say why it died.
    grep -E -A3 '^(Exception Type|Exception Codes|Exception Note|Termination Reason|Termination Description|Triggered by Thread|Crashed Thread|Application Specific Information)' "$work/crash.ips" | head -60
    if grep -q '"threads"' "$work/crash.ips"; then
        # A JSON body (the format ipsw cannot parse for some reports): print why it died and the
        # crashed thread's frames, symbolicating the shared-cache ones with `ipsw dyld a2s`.
        python3 - "$work/crash.ips" > "$work/frames.txt" <<'PY'
import json, sys
text = open(sys.argv[1]).read()
body = json.loads(text[text.index("\n") + 1:])
for key in ("exception", "termination", "asi", "ktriageinfo", "lastExceptionBacktrace"):
    if key in body:
        print(key, json.dumps(body[key])[:600])
images = body.get("usedImages", [])
cache = body.get("sharedCache", {})
slide = cache.get("base", 0x180000000) - 0x180000000 if cache.get("base") else 0
thread = next((t for t in body.get("threads", []) if t.get("triggered")), body.get("threads", [{}])[0])
print("thread", thread.get("name", ""), thread.get("queue", ""))
def image(i):
    img = images[i] if 0 <= i < len(images) else {}
    if isinstance(img, list):  # older reports: [uuid, base, type]
        ints = [v for v in img if isinstance(v, int)]
        img = {"base": ints[0] if ints else 0, "name": next((v for v in img if isinstance(v, str) and "/" in v), "?")}
    return img
for f in thread.get("frames", []):
    if isinstance(f, list):  # older reports: [imageIndex, imageOffset]
        f = {"imageIndex": f[0], "imageOffset": f[1]}
    img = image(f.get("imageIndex", -1))
    addr = img.get("base", 0) + f.get("imageOffset", 0)
    name = img.get("name") or img.get("path", "?").rsplit("/", 1)[-1]
    unslid = addr - slide if addr - slide >= 0x180000000 else 0
    print(f"FRAME {name} +{f.get('imageOffset', 0):#x} {f.get('symbol', '')} @{unslid:#x}")
PY
        while read -r line; do
            a=$(printf '%s' "$line" | grep -o '@0x[0-9a-f]*' | tr -d @)
            if [ -n "$a" ] && [ "$a" != 0x0 ]; then
                sym=$("$ipsw" dyld a2s "$dsc" "$a" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -v '^[[:space:]]*$' | tail -1 | cut -c1-200)
                echo "$line   $sym"
            else
                echo "$line"
            fi
        done < "$work/frames.txt" | head -80
    else
        "$ipsw" symbolicate "$work/crash.ips" "$dsc" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -v 'failed to parse objc' | head -220
    fi
fi

[ -f "$work/stackshot.ips" ] || exit 0
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
