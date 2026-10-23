#!/usr/bin/env python3
"""Writes the SideStore / AltStore source (sidestore.json) for the rolling release.

    scripts/make-sidestore-source.py --ipa out/IOSEmul.ipa \
        --repo owner/name --tag Rolling --out out/sidestore.json

The source lists one app with one version: the IPA attached to the rolling release. Both the
current "versions" schema and the legacy top-level version fields are written so older SideStore
and AltStore clients can read it as well.

The version, build version, bundle identifier and minimum iOS are read from the IPA's Info.plist,
and the entitlements from the app binary's code signature: SideStore and AltStore refuse an install
whose IPA does not match the source (they take a missing buildVersion to be the same as version,
and require every signed entitlement to be listed under appPermissions).
"""
import argparse
import datetime
import json
import os
import plistlib
import re
import struct
import zipfile

WHATS_NEW = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "distribution", "whats-new.md")


def whats_new(path=WHATS_NEW, sections=2):
    """The newest dated sections of distribution/whats-new.md as plain text for SideStore."""
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        return ""
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    out, count = [], 0
    for line in text.splitlines():
        heading = re.match(r"##\s+(.+)", line)
        if heading:
            count += 1
            if count > sections:
                break
            out.append(("" if not out else "\n") + heading.group(1).strip())
        elif count and line.strip():
            out.append(re.sub(r"^\s*[-*]\s+", "• ", line.rstrip()))
    return "\n".join(out).strip()


def bundle_info(ipa):
    """The app's Info.plist from an IPA (Payload/<name>.app/Info.plist)."""
    with zipfile.ZipFile(ipa) as z:
        name = next(n for n in z.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n))
        return plistlib.loads(z.read(name))


def entitlements(ipa, executable):
    """The entitlements signed into the app's main executable (an arm64 Mach-O)."""
    with zipfile.ZipFile(ipa) as z:
        name = next(n for n in z.namelist() if re.fullmatch(r"Payload/[^/]+\.app/" + re.escape(executable), n))
        data = z.read(name)
    if struct.unpack_from("<I", data, 0)[0] != 0xFEEDFACF:
        raise SystemExit(f"{name}: not a thin 64-bit Mach-O")
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == 0x1D:                                     # LC_CODE_SIGNATURE
            sig = struct.unpack_from("<I", data, off + 8)[0]
            magic, _, count = struct.unpack_from(">III", data, sig)
            if magic != 0xFADE0CC0:                         # embedded signature super blob
                break
            for i in range(count):
                _, blob = struct.unpack_from(">II", data, sig + 12 + i * 8)
                bmagic, blen = struct.unpack_from(">II", data, sig + blob)
                if bmagic == 0xFADE7171:                    # XML entitlements
                    return plistlib.loads(data[sig + blob + 8:sig + blob + blen])
            break
        off += size
    return {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ipa")
    ap.add_argument("--repo", help="owner/name on GitHub")
    ap.add_argument("--tag", default="Rolling")
    ap.add_argument("--commit", default="")
    ap.add_argument("--out")
    ap.add_argument("--no-core", action="store_true", help="the IPA was built without QEMU")
    ap.add_argument("--print-notes", action="store_true",
                    help="only print the What's New text (for the release page) and exit")
    args = ap.parse_args()
    if args.print_notes:
        print(whats_new())
        return
    if not (args.ipa and args.repo and args.out):
        ap.error("--ipa, --repo and --out are required")
    info = bundle_info(args.ipa)
    short_version = info["CFBundleShortVersionString"]
    build_version = info["CFBundleVersion"]
    signed = entitlements(args.ipa, info["CFBundleExecutable"])
    privacy = {k: v for k, v in info.items() if k.startswith("NS") and k.endswith("UsageDescription")}

    base = f"https://github.com/{args.repo}"
    raw = f"https://raw.githubusercontent.com/{args.repo}/HEAD"
    download = f"{base}/releases/download/{args.tag}/{os.path.basename(args.ipa)}"
    size = os.path.getsize(args.ipa)
    date = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    notes = f"Rolling build of {args.commit[:7]}." if args.commit else "Rolling build."
    if args.no_core:
        notes += " This build has no emulator core yet: IPSWs can be inspected but not booted."
    changes = whats_new()
    if changes:
        notes = changes + "\n\n" + notes
    description = ("Boots iPhone, iPad and iPod touch IPSW firmware in an emulated Apple machine "
                   "(QEMU), entirely on the device.")

    version = {
        "version": short_version,
        "buildVersion": build_version,
        "date": date,
        "localizedDescription": notes,
        "downloadURL": download,
        "size": size,
        "minOSVersion": info.get("MinimumOSVersion", "16.0"),
    }
    app = {
        "name": "iOS Emul",
        "bundleIdentifier": info["CFBundleIdentifier"],
        "developerName": args.repo.split("/")[0],
        "subtitle": "Run IPSW firmware in an emulator",
        "localizedDescription": description,
        "iconURL": f"{raw}/distribution/icon.png",
        "tintColor": "3C78D8",
        "category": "developer",
        "versions": [version],
        # Legacy fields for clients that predate "versions".
        "version": version["version"],
        "versionDate": date,
        "versionDescription": notes,
        "downloadURL": download,
        "size": size,
        "appPermissions": {"entitlements": sorted(signed), "privacy": privacy},
    }
    source = {
        "name": "iOS Emul",
        "identifier": "com.iosemul.source",
        "subtitle": "Rolling builds of iOS Emul",
        "website": base,
        "iconURL": f"{raw}/distribution/icon.png",
        "tintColor": "3C78D8",
        "apps": [app],
        "news": [],
    }
    with open(args.out, "w") as f:
        json.dump(source, f, indent=2)
        f.write("\n")
    print(f"wrote {args.out}: {short_version} ({build_version}), {size} bytes, entitlements {sorted(signed)}")


if __name__ == "__main__":
    main()
