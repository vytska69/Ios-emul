#!/bin/bash
# Prints the emulated iPhone's unified log (os_log) for chosen processes (macOS CI, after QEMU has
# stopped): copies /private/var/db/diagnostics and uuidtext off the Data volume into a .logarchive
# and reads it with `log show`.
#
#     scripts/ci-guest-log.sh vm/nvme.1 'process == "backboardd"' [lines]
#
# LOG_HEAD=1 prints the first lines instead of the last.
set -u
disk=${1:?usage: ci-guest-log.sh nvme.1 predicate [lines]}
predicate=${2:-}
lines=${3:-200}
work=$(mktemp -d)
archive=$work/guest.logarchive
mkdir -p "$archive"

bash "$(dirname "$0")/ci-mount-volume.sh" "$disk" Data "
    cp -R \"\$MNT\"/db/diagnostics/. '$archive/' 2>/dev/null
    cp -R \"\$MNT\"/db/uuidtext/. '$archive/' 2>/dev/null
    chmod -R a+rX '$archive'" >/dev/null
echo "== $(find "$archive" -type f | wc -l | tr -d ' ') files in the log archive"
# log show wants an Info.plist naming the archive's layout.
[ -f "$archive/Info.plist" ] || cat > "$archive/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>OSArchiveVersion</key><integer>4</integer></dict></plist>
EOF
if [ -n "$predicate" ]; then
    log show --archive "$archive" --info --debug --style compact --predicate "$predicate" 2>&1 \
        | if [ -n "${LOG_HEAD:-}" ]; then head -n "$lines"; else tail -n "$lines"; fi
else
    log show --archive "$archive" --info --style compact 2>&1 | tail -n "$lines"
fi
