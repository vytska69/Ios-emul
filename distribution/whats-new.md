# What's new

<!--
Shown to users in SideStore ("What's New") and on the Rolling release page.
Every change to the app adds a line here, in plain words for someone who just uses the app:
what they will notice, not how it was done. Changes made on the same day go under that day's
heading; a new day starts a new "## YYYY-MM-DD" section at the top. The newest sections are
published with each build (scripts/make-sidestore-source.py).
-->

## 2026-10-23

- While a machine starts, the screen now tells you whether QEMU is still building it or the machine is already running and the display is not on yet.
- Each firmware now shows a badge for its iOS version, in that release's colours, in the library, the download list and the firmware page.
- The machine screen no longer gets stuck on "Starting QEMU…": it keeps trying to show the display and counts how long it has been waiting.
- While the display is not up yet, you see what the emulated device prints as it starts (or QEMU's own messages before that), so you can tell whether it is still working.
- Fixed machines failing to start with "could not read keymap file 'en-us'".
- New look: redesigned screens, themes, and a separate Settings tab.
- New About page with the version and a link to the source code. Tap the version number 7 times to unlock Experimental features.
- Experimental: settings applied inside the emulated iOS from its first start, such as VoiceOver, larger text, dark mode, language and region, device name and skipping the setup screens.
- Experimental: machine tools (pause, resume, reset, screenshot, QEMU console), log viewer, IPSW file explorer and DeviceTree browser.
- The app stays smooth while an IPSW downloads or installs, and an interrupted download resumes where it stopped.
- Fixed installs failing with "Corrupt compressed data (deflate)".
- Instead of the app closing, you now get a clear message when JIT is not enabled or the device does not have enough free memory.
- Fixed the emulator failing with "allocate … bytes for jit buffer: Operation not permitted" when JIT is enabled.
