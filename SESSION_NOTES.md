# Session notes

## 2026-05-07 — Phase 1: scaffold

First session on the iOS port. Worked from `docs/ios-port-handoff.md` in
the (private) Android repo `suplyai/echo-air`. The handoff doc remains
the source of truth for invariants — this file only captures what was
decided in-session and what state the next session inherits.

### What was done

Phase 1 of the 7-phase build sequence: empty repo scaffold. Single
commit (`444d7c9`) on `main`, pushed to origin.

- `project.yml` — xcodegen spec, source of truth. `EchoAir.xcodeproj/`
  is gitignored.
- `Config/{Shared,Debug,Release}.xcconfig` — `API_BASE_URL =
  https://suply.app/` shared across configs (no debug override yet).
- `EchoAir/Info.plist` — bundle metadata, all three privacy strings
  (`NSBluetoothAlwaysUsageDescription`,
  `NSLocationWhenInUseUsageDescription`, `NSCameraUsageDescription`),
  `bluetooth-central` background mode, portrait-only, `bluetooth-le`
  required, `ITSAppUsesNonExemptEncryption=false`,
  `API_BASE_URL` exposed to runtime via Info dictionary.
- `EchoAir/Resources/PrivacyInfo.xcprivacy` — iOS 17+ manifest.
  UserDefaults CA92.1, Coarse Location (linked), Other Device IDs
  (unlinked).
- `EchoAir/App/{EchoAirApp,ContentView}.swift` — SwiftUI placeholder
  so the app launches with a recognisable screen.
- `.gitignore`, `README.md`.

Bundle IDs (`app.suply.echoair` release, `app.suply.echoair.debug`
debug), deployment target (16.0), iPhone-only, marketing version
0.6.1, build number 1 are wired in.

### Three flagged decisions worth revisiting

1. **Coarse vs Precise location in `PrivacyInfo.xcprivacy`.**
   The handoff doc §6/§7 says "Coarse Location" and the manifest
   currently declares `NSPrivacyCollectedDataTypeCoarseLocation`. But
   BLE collection (per handoff doc §3.6) uses
   `kCLLocationAccuracyBest`, which Apple defines as Precise. Mirrored
   the doc verbatim per the "translate exactly" rule, but expect this
   to draw a reviewer note at App Store submission. Resolve by
   submission time — either declare Precise, or downgrade the runtime
   accuracy to ~3 km. The latter probably breaks the audit-trail value.

2. **`SWIFT_STRICT_CONCURRENCY: complete` is on.** Catches Sendable
   issues at compile time, which is the right default for a fresh
   project. But porting Kotlin coroutines + Combine + CoreBluetooth
   delegate callbacks may produce churn. If it slows the port, dial
   back to `targeted` (set on individual files only) or `minimal` in
   `project.yml` `settings.base`. Don't silently turn it off without
   noting the regression.

3. **`API_BASE_URL = https:/$()/suply.app/` in `Config/Shared.xcconfig`.**
   The `$()` between the slashes is the documented xcconfig escape for
   the `//` comment marker — without it the value would be truncated
   at the second slash and runtime URL parsing would fail
   non-obviously. Anyone editing the URL without knowing this will
   break it. The comment in the file explains the trick; preserve it.

### Deferred to phase 2

The handoff doc lists phase 2 as: pod-install kbeaconlib2 + build a
spike harness (mirror of Android's `SpikeActivity`) before any further
app structure. This session did not start phase 2 because the local
toolchain isn't ready (see below). Specifically deferred:

- `Podfile` + `pod 'kbeaconlib2', '~> 1.2'`.
- Spike harness target/scheme calling `connectEnhanced`,
  `readSensorDataInfo`, `readSensorRecord` against a real S23H. Must
  confirm: `KBSensorReadOption.NormalOrder` works, initial cursor `0`
  works (NOT `INVALID_DATA_RECORD_POS` despite the constant's name),
  paged reads of 200 records work, `syncUtcTime=false` preserves
  device clock drift so backend `device_clock_offset_seconds` remains
  meaningful.
- Decision on whether to migrate kbeaconlib2 to vendored source or an
  SPM-wrapper before App Store submission (CocoaPods Trunk is going
  read-only ~Jan 2027). Recommend: stay on `pod install` until the
  spike works, then vendor before submission.

### Tooling state on this Mac

- Xcode: **not installed** — only Command Line Tools (`xcodebuild`
  errors out). Phase 2 is blocked on installing Xcode 15+ from the App
  Store (or via `xcodes`).
- CocoaPods: not installed. `brew install cocoapods` or
  `sudo gem install cocoapods`.
- xcodegen: not installed. `brew install xcodegen` is required to
  regenerate `EchoAir.xcodeproj/` from `project.yml`.
- swiftformat / swiftlint: not installed. Out of scope for v1.
- macOS 26.3 (Tahoe) — recent enough for any modern Xcode.

The scaffold was authored without ever invoking Xcode, by design
(user choice once tooling absence was discovered). All settings flow
through `project.yml` + `Info.plist` + xcconfigs, so opening the
project for the first time should be a clean experience.

### Auth setup (one-time, already done)

- GitHub SSH host keys (RSA, ECDSA, Ed25519) were added to
  `~/.ssh/known_hosts` after verifying their fingerprints against
  https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints.
- `origin` was switched from SSH to HTTPS
  (`https://github.com/suplyai/echo-air-ios.git`) because no SSH key
  on this machine is registered with the GitHub account. If you
  prefer SSH long-term, generate a key (`ssh-keygen -t ed25519`),
  add the public key at https://github.com/settings/ssh/new, then
  `git remote set-url origin git@github.com:suplyai/echo-air-ios.git`.
- HTTPS pushes need a Personal Access Token. The osxkeychain helper
  is configured but had no GitHub credential cached at session start.
  After the first push from a terminal that prompts for username +
  PAT, keychain remembers it and subsequent pushes are silent.

### Next session pickup

In this order:

1. **Read the handoff doc first.** It lives at
   `docs/ios-port-handoff.md` in the Android repo. Sections to focus
   on for phase 2: §1 (KKM SDK scan), §2 step 2 (spike), §3.10 (BLE
   operational constants — these are the spike's pass criteria).
2. **Install tooling.** `brew install xcodegen cocoapods` and Xcode
   15+ from the App Store. Confirm with `xcodebuild -version`.
3. **Bring up the project.** `xcodegen generate`, open
   `EchoAir.xcodeproj`, set `DEVELOPMENT_TEAM` to the Suply Apple
   Developer team, build and run the SwiftUI placeholder on a
   simulator and on a real iPhone.
4. **Start phase 2.** `pod init`, add `pod 'kbeaconlib2', '~> 1.2'`,
   `pod install`, switch to `EchoAir.xcworkspace`. Build a spike
   target (or a debug-only scheme) that connects to a real S23H,
   reads sensor info + 200 records, prints to console. Validate the
   four invariants from §3.10 before declaring phase 2 done.
5. **Decide marketing version trajectory.** Currently 0.6.1 to match
   Android. App Store debut narrative argues for 1.0.0 — open
   question per handoff doc §11. Doesn't block phase 2.

Out of scope until phase 3+: any UI beyond the placeholder, DTOs,
networking, AWB validation, IATA lookup, locale system, BLE
collection orchestrator, location capture, MPS rendering,
finalize/stale logic, BT/location reactive gates, App Store cleanup.
