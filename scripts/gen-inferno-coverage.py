#!/usr/bin/env python3
"""Lists the DeviceTree nodes each Inferno machine model instantiates.

Inferno builds peripherals by looking up DeviceTree nodes by name, so the node names its machine
sources mention are the hardware it emulates. The output feeds EmulatorKit's coverage report.

    scripts/gen-inferno-coverage.py <QEMUAppleSilicon checkout> > Sources/EmulatorKit/Resources/inferno-nodes.json
"""
import json
import re
import subprocess
import sys
from pathlib import Path

PATTERNS = [
    r'apple_dt_get_node\([^,]+,\s*"([^"]+)"',               # explicit lookups
    r'_create_(?:gpio|i2c|spmi|spi)\([^,]+,\s*"([^"]+)"',    # loop helpers
    r'object_property_get_link\([^,]+,\s*"([^"]+)"',          # peripherals wired by name
]
IGNORE = {"chosen", "arm-io", "cpus", "product", "memory-map", "carveout-memory-map", "lock-regs", "amcc"}


def nodes(source: str) -> list:
    found = set()
    for pattern in PATTERNS:
        for path in re.findall(pattern, source):
            name = path.rstrip("/").split("/")[-1]
            if name and name not in IGNORE:
                found.add(name)
    for n in re.findall(r'"spi%u"', source):
        found.update(f"spi{i}" for i in range(4))
    return sorted(found)


def main() -> None:
    root = Path(sys.argv[1])
    rev = subprocess.run(["git", "-C", str(root), "rev-parse", "--short", "HEAD"],
                         capture_output=True, text=True).stdout.strip()
    out = {"source": "https://github.com/ChefKissInc/QEMUAppleSilicon", "revision": rev, "machines": {}}
    for machine in ("t8030", "s8000"):
        src = (root / "hw/arm/apple-silicon" / f"{machine}.c").read_text(errors="replace")
        out["machines"][machine] = nodes(src)
    json.dump(out, sys.stdout, indent=1)
    print()


if __name__ == "__main__":
    main()
