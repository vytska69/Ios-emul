# What's new

<!--
Shown to users in SideStore ("What's New") and on the Rolling release page.
Every change to the app adds a line here, in plain words for someone who just uses the app:
what they will notice, not how it was done. Changes made on the same day go under that day's
heading; a new day starts a new "## YYYY-MM-DD" section at the top. The newest sections are
published with each build (scripts/make-sidestore-source.py).
-->

## 2026-10-31
- Sound: the emulated phone's sound no longer stutters. It was cut into short pieces with gaps of silence in between, because the emulated phone produces sound unevenly; the app now keeps a quarter second in hand and plays it smoothly, waiting briefly when the phone falls behind instead of breaking up every sound.
- iPhone 11 iOS 14: fixed the phone crashing (restarting) shortly after the home screen appeared, which the sound change above caused in the previous build.
- Faster: new boots now use 4 emulated CPU cores instead of 2 on iPhones and iPads with 6 or more cores (unless you changed the number in Settings), and the boot no longer writes a log line for every driver it loads.

## 2026-10-28
- iPhone 11 iOS 14: the emulated phone now makes sound. Its audio system used to stay switched off (no speaker was ever set up), so nothing played, VoiceOver included; now the speaker is found and what the phone plays reaches the app (new installs).
- iPhone 11 iOS 14: the emulated phone now has 32 GB of storage instead of 8 GB, of which only about 200 MB were free; about 25 GB are now free for apps and data (new installs).

## 2026-10-27
- iPhone 11 iOS 14: no more passcode. Swiping up on the lock screen now opens the home screen; before, iOS asked for a passcode that was never set (new installs).
- iPhone 11 iOS 14: Setup no longer jumps back to the "Hello" screen after you swipe up. The screen-drawing part of iOS crashed there because the emulated phone has no graphics chip; now the swipe leads on (for now to the passcode screen) (new installs).
- Sound: the app's audio no longer stays off when it stops on its own while a machine runs; it is checked every second and started again. Settings → Emulator → Sound now also shows whether the emulated phone has played any sound at all and the last audio error.
- Settings → Emulator has a new Sound section: a "Play test tone" button that plays a short tone through the app's own audio (no emulator involved), and a live sound status. If the tone is heard but the emulated phone is silent, the app's audio works and the phone is making no sound; if the tone is not heard either, the app's audio output is the problem.
- Sound: the emulated phone's sound should now actually play. The app could not reach the emulator's audio at all — the function it reads sound from was missing from the build it loads, so nothing ever came out (for example VoiceOver could not be heard). That connection is now in place, together with the earlier fix that waits for the emulator to finish loading before hooking up the sound.

- The emulated touch screen now keeps reporting a finger that is held still, which should make taps that do not move (for example with a stylus or a mouse) register (not yet confirmed).
- iPhone 11 iOS 14: the touch screen setup no longer depends on the exact iOS 14.0 build, so it can work on other iOS 14 versions too (not yet tried).
- iPhone 11 iOS 14: an experimental change for the passcode screen that appears after unlocking: try entering any passcode.
- iPhone 11 iOS 14: the touch screen works. Swiping up on the lock screen now opens it (new installs). iOS then asks for a passcode even though none was set; that is not solved yet.

## 2026-10-26

- iPhone 11 iOS 14: the installer now puts the touch screen's firmware where iOS looks for it, so the emulated touch screen can be switched on (new installs; work in progress, touches may not work yet).
- iPhone 11 iOS 14: if the first start after installing was interrupted (the app closed or the machine was stopped), the emulated phone no longer restarts in an endless loop with a black screen; the next start finishes setting it up.
- iPhone 11 iOS 14: the emulated touch screen is now picked up by iOS. Before, iOS started a touch driver that cannot work without Apple's authentication chip, and every touch was ignored (new installs).
- Sound: the emulated phone's sound now plays through your phone's speaker (before, the app had no sound output at all, so for example VoiceOver was silent).
- Touches at the very bottom edge of the emulated screen now register, so swiping up from the bottom to unlock or go home can work (before, they landed outside the screen).
- "Skip setup" now really skips the setup assistant on iOS 14: before, iOS showed the Hello screen anyway. The installer marks setup as finished for this iOS version and turns off iOS's checks for it (new installs; not yet tried on a phone).

## 2026-10-25

- The Home and Lock buttons now work: Lock presses the emulated phone's side button, and Home swipes up from the bottom edge as on a Face ID iPhone (the home button on older models). Before, both did nothing. New volume down and up buttons next to them.
- The emulated phone now keeps running when you leave the app or lock your phone, so a long first start can go on while you do something else (Settings > Emulator > Run in background, on by default). It uses battery and warms the phone, and iOS can still close the app if memory runs short.
- New Settings > Diagnostics page: shows whether the app was installed with everything the emulator needs (JIT permission, extra memory, large address space) and how much memory iOS allows it, with a button to copy the report. Some installers quietly leave these out, and then the emulator does not start.
- While the emulated phone starts, the screen now shows how far it has got (machine built, kernel started, drivers, system disk, iOS starting, waiting for the first screen) with the time spent on each step, instead of a black screen that looks stuck. A kernel panic is shown there too.
- Once the emulated screen shows the Apple logo, the start-up progress moves to a small bar at the top of the screen instead of covering the logo; tap it to see all the steps. It also says whether the emulated processor is moving, so a slow start can be told apart from a stuck one.
- Start-up progress no longer ticks off every step within seconds: it was reading the previous start's log.
- The start-up bar now counts all emulated processor cores ("3 of 4 CPUs working · running"), so a core that is simply waiting for work no longer reads as "not moving".
- Installing iOS no longer piles up memory while it unpacks the system: the phone stays responsive and the app is no longer closed by iOS partway through the install.
- Faster emulation: the translation cache now defaults to 512 MB. With 256 MB the emulator kept throwing away all translated code and starting over while iOS booted. A build earlier today used 1024 MB, which with 4 GB of guest memory was too much for the phone and the app closed right after "Building the machine"; reopen the app (through StikDebug) after updating.
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
