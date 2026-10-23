VNC keyboard layouts from QEMU (`pc-bios/keymaps` at the pinned Inferno revision, GPL-2.0-or-later).

QEMU's VNC server loads `en-us` at start-up and exits if it cannot. The IPA workflow copies these
into the app's `QEMUData/keymaps` on every build, so they are there even when the QEMU frameworks
come from the build cache (which holds only `App/Frameworks`).
