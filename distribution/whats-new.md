# What's new

<!--
Shown to users in SideStore ("What's New") and on the Rolling release page.
Every change to the app adds a line here, in plain words for someone who just uses the app:
what they will notice, not how it was done. Changes made on the same day go under that day's
heading; a new day starts a new "## YYYY-MM-DD" section at the top. The newest sections are
published with each build (scripts/make-sidestore-source.py).
-->

## 2026-10-25

- Faster emulation: the translation cache now defaults to 512 MB. With 256 MB the emulator kept throwing away all translated code and starting over while iOS booted. If you picked 256 MB in Settings yourself, switch to 512 MB or more.
- iPhone 11 iOS 14: the first start reaches the setup screen several minutes sooner; the emulated phone no longer runs the data migration a new install does not need (new installs).
- iOS no longer keeps re-saving its encryption keys several times a second in the background, which left less of the processor for everything else.

## 2026-10-24

- iPhone 11 iOS 14: the screen now shows iOS instead of staying black. The emulated phone has no graphics chip, so the installer adjusts a few spots in iOS so it draws everything on the processor (new installs; first start takes about 20 minutes).
- The emulated display now refreshes on its own at 60 Hz, so iOS keeps drawing even when no screen is watching (for example with the app in the background).
- iPhone 11 iOS 14: the emulated Secure Enclave now reports the phone as unlocked (no passcode), which the Photos service waits for on the first start (experimental).
- iPhone 11 iOS 14: the phone (cellular) service is switched off, as the emulated phone has no modem; it kept crashing and held up the first start (experimental).
- iPhone 11 iOS 14: the installed system is marked as already migrated to its version (part of the work on the black screen after the first start).
- iPhone 11 iOS 14: iOS no longer kills the home screen and apps for starting too slowly, which they always do under emulation (new installs).

## 2026-10-23

- iPhone 11 iOS 14 now starts past the first-start setup into the system: the display backlight comes on. Fixed a crash ("spinlock timeout") that came soon after.
- iPhone 11 iOS 14: the first-start erase no longer starts over on every restart.
- iPhone 11 iOS 14: on the first start the user data storage is kept and prepared in place, so iOS can save its encryption keybag (experimental).
- The emulator debug log now also records what iOS asks of the emulated Secure Enclave, to help get iPhone 11 past its first start.
- iPhone 11 iOS 14: the first start can now erase and recreate the user data storage, as a real iPhone does. Existing iPhone 11 machines reinstall iOS once on their next start.
- Experimental fix for the first start of iPhone 11 iOS 14 stopping at "Failed to write effaceable.": the emulated storage that holds iOS's encryption lockers is now accepted when blank.
- Settings → Emulator → Engine is always shown, and says when a build has only one engine.
- New Enable JIT with StikDebug button (Settings → Emulator, and on the firmware page when JIT is off): it opens StikDebug with the right script for this app, then prepares JIT memory once it has attached. No need to pick a script in StikDebug yourself.
- Fixed the no-JIT interpreter missing from the app (it failed to build).
- JIT on iOS 26 and later (iPhone 15 Pro, 16, 16e, 17 and newer): the app now asks StikDebug for its JIT memory the way these devices require, so machines no longer stop right after starting. In StikDebug, use the universal.js script for iOS Emul.
- The app now runs without JIT too: it includes a slower interpreter and uses it automatically when JIT is not enabled. You can also pick JIT or Interpreter yourself under Settings → Emulator → Engine, e.g. if a machine stops right after starting with JIT on.
- iPod touch 1G/2G firmware is now marked as not supported yet in the app, instead of asking for a boot ROM file it could not use.
- While waiting for the display, the screen shows where the emulated processor is and whether it is moving, to tell a slow start from a stuck one.
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
