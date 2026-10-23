#!/usr/bin/env python3
"""Writes the SideStore / AltStore source (sidestore.json) for the rolling release.

    scripts/make-sidestore-source.py --ipa out/IOSEmul.ipa \
        --repo owner/name --tag Rolling --out out/sidestore.json

The source lists one app with one version: the IPA attached to the rolling release. Both the
current "versions" schema and the legacy top-level version fields are written so older SideStore
and AltStore clients can read it as well.

The version, build version, bundle identifier and minimum iOS are read from the IPA's Info.plist:
SideStore and AltStore refuse an install whose IPA does not match the source (and take a missing
buildVersion to be the same as version).
"""
import argparse
import datetime
import json
import os
import plistlib
import re
import zipfile


def bundle_info(ipa):
    """The app's Info.plist from an IPA (Payload/<name>.app/Info.plist)."""
    with zipfile.ZipFile(ipa) as z:
        name = next(n for n in z.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n))
        return plistlib.loads(z.read(name))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ipa", required=True)
    ap.add_argument("--repo", required=True, help="owner/name on GitHub")
    ap.add_argument("--tag", default="Rolling")
    ap.add_argument("--commit", default="")
    ap.add_argument("--out", required=True)
    ap.add_argument("--no-core", action="store_true", help="the IPA was built without QEMU")
    args = ap.parse_args()
    info = bundle_info(args.ipa)
    short_version = info["CFBundleShortVersionString"]
    build_version = info["CFBundleVersion"]

    base = f"https://github.com/{args.repo}"
    raw = f"https://raw.githubusercontent.com/{args.repo}/HEAD"
    download = f"{base}/releases/download/{args.tag}/{os.path.basename(args.ipa)}"
    size = os.path.getsize(args.ipa)
    date = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    notes = f"Rolling build of {args.commit[:7]}." if args.commit else "Rolling build."
    if args.no_core:
        notes += " This build has no emulator core yet: IPSWs can be inspected but not booted."
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
        "appPermissions": {"entitlements": [], "privacy": {}},
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
    print(f"wrote {args.out}: {short_version} ({build_version}), {size} bytes")


if __name__ == "__main__":
    main()
