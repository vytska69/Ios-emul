#!/bin/bash
# Experiment (macOS CI): patches instructions of the emulated iPhone's dyld shared cache in place on
# its disk image, after an install and before the next boot. Each patch is VMADDR=OLD:NEW (32-bit
# instruction words, hex); NEW may be "bl:SYMBOL-IN-IMAGE", a bl to that image's stub for SYMBOL.
#
#     IMAGE=MobileIcons scripts/ci-patch-dsc.sh vm/nvme.1 0x1a647e260=0x94000041:0xd503201f \
#         0x1a647e26c=0x9400003e:bl:_CGImageRetain
#
# The file's blocks are found with F_LOG2PHYS_EXT on the read-only mounted System volume and the
# words are written straight into the image, so the volume itself is not modified through APFS.
set -u
disk=${1:?usage: ci-patch-dsc.sh nvme.1 patches...}
shift
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)

offset=$(python3 -c '
import sys
f = open(sys.argv[1], "rb")
for o in range(0, 16 << 20, 4096):
    f.seek(o + 32)
    if f.read(4) == b"NXSB":
        print(o); break
' "$disk")
[ -n "$offset" ] || { echo "== no APFS container in $disk"; exit 1; }

# A "bl:SYMBOL" patch needs the address of the image's stub for SYMBOL: take it from a call to it
# in the image's own code.
stubs=
if printf '%s\n' "$@" | grep -q ':bl:'; then
    bash "$here/ci-mount-volume.sh" "$disk" System "
        cp \"\$MNT\"/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e '$work/dsc'
        chmod a+r '$work/dsc'" >/dev/null
    mkdir -p "$work/ipsw"
    for tag in $(gh release list -R blacktop/ipsw -L 15 --json tagName -q '.[].tagName'); do
        gh release download "$tag" -R blacktop/ipsw --pattern 'ipsw_*_macOS_universal.tar.gz' -D "$work/ipsw" \
            >/dev/null 2>&1 && break
    done
    for t in "$work"/ipsw/*.tar.gz; do tar -xzf "$t" -C "$work/ipsw"; done
    for candidate in $(find "$work/ipsw" -type f -perm -u+x); do
        if "$candidate" dyld --help >/dev/null 2>&1; then ipsw=$candidate; break; fi
    done
    "$ipsw" dyld disass "$work/dsc" --image "${IMAGE:?IMAGE is needed for bl: patches}" 2>/dev/null \
        | sed 's/\x1b\[[0-9;]*m//g' > "$work/image.s"
    echo "== $(wc -l < "$work/image.s") lines of $IMAGE"
    stubs=$work/image.s
fi

python3 - "$offset" "$disk" "$stubs" "$@" <<'EOF'
import re, struct, subprocess, sys

container, disk, stubs, patches = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4:]

def stub_for(symbol):
    # "0x1a647e2f0:  xx xx xx xx   bl  j__CGImageRetain": decode the bl to get the stub address.
    for line in open(stubs):
        m = re.match(r"(0x[0-9a-f]+):\s+((?:[0-9a-f]{2} ){4})\s*bl\s+(?:j_)?" + re.escape(symbol) + r"\s*$", line)
        if m:
            addr, word = int(m.group(1), 16), int.from_bytes(bytes.fromhex(m.group(2)), "little")
            imm = word & 0x3FFFFFF
            if imm & 0x2000000:
                imm -= 1 << 26
            return addr + imm * 4
    sys.exit(f"no call to {symbol} in the image")

todo = []
for p in patches:
    addr, words = p.split("=", 1)
    old, new = words.split(":", 1)
    addr, old = int(addr, 16), int(old, 16)
    if new.startswith("bl:"):
        target = stub_for(new[3:])
        new = 0x94000000 | (((target - addr) >> 2) & 0x3FFFFFF)
        print(f"== {p}: stub at {target:#x}")
    else:
        new = int(new, 16)
    todo.append((addr, old, new))

# Mount System read-only and map each address to an offset on the container's device.
out = subprocess.run(["bash", "-c", f"""
    bash scripts/ci-mount-volume.sh {disk} System 'python3 - "$MNT"/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e {" ".join(f"{a:#x}" for a, _, _ in todo)} <<"PY"
import fcntl, struct, sys
f = open(sys.argv[1], "rb")
head = f.read(0x200)
moff, mcount = struct.unpack_from("<II", head, 0x10)
f.seek(moff)
maps = [struct.unpack("<QQQII", f.read(32)) for _ in range(mcount)]
for a in sys.argv[2:]:
    a = int(a, 16)
    for addr, size, fileoff, _, _ in maps:
        if addr <= a < addr + size:
            off = fileoff + a - addr
            break
    else:
        print("MISS", hex(a)); continue
    f.seek(off)
    word = struct.unpack("<I", f.read(4))[0]
    # struct log2phys (packed to 4): flags, contigbytes, devoffset.
    arg = struct.pack("=Iqq", 0, 4, off)
    res = fcntl.fcntl(f.fileno(), 65, arg)  # F_LOG2PHYS_EXT
    _, contig, dev = struct.unpack("=Iqq", res)
    print("MAP", hex(a), off, dev, hex(word))
PY'
"""], capture_output=True, text=True)
print(out.stdout, out.stderr, end="")
found = {}
for line in out.stdout.splitlines():
    if line.startswith("MAP "):
        _, a, off, dev, word = line.split()
        found[int(a, 16)] = (int(dev), int(word, 16))

with open(disk, "r+b") as d:
    for addr, old, new in todo:
        if addr not in found:
            sys.exit(f"{addr:#x}: not mapped")
        dev, word = found[addr]
        d.seek(container + dev)
        raw = struct.unpack("<I", d.read(4))[0]
        if raw != old or word != old:
            sys.exit(f"{addr:#x}: expected {old:#010x}, file has {word:#010x}, disk has {raw:#010x}")
        d.seek(container + dev)
        d.write(struct.pack("<I", new))
        print(f"== patched {addr:#x} at disk offset {container + dev}: {old:#010x} -> {new:#010x}")
EOF
