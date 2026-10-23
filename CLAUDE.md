# Notes for working on this repo

- Every change that reaches the app (anything under `App/`, `Sources/IPSWKit`, `Sources/EmulatorKit`,
  `qemu/`) adds a line to `distribution/whats-new.md` in the same commit. Write it for someone who
  only uses the app: what they will notice, in plain words, not how it was done. Changes on the same
  day go under that day's `## YYYY-MM-DD` heading; a new day starts a new section at the top. The
  IPA workflow publishes the newest sections to SideStore ("What's New") and the Rolling release.
- Harness, test and documentation changes that users never see do not go in `whats-new.md`.
