# Session notes

## 2026-05-08 — Phase 2: scaffold (no build)

Phase 2 prep authored remotely on the web. There is no Xcode / CocoaPods
/ xcodegen on this orchestrating machine — those steps run on the iOS
engineer's Mac. This session writes source files only; the engineer
runs `xcodegen generate`, `pod install`, and the actual build /
on-device spike.

### What was done

- `Podfile` — `pod 'kbeaconlib2', '~> 1.2'`, target `EchoAir`,
  `use_frameworks!`, `platform :ios, '16.0'`. `post_install` clamps
  pod deployment targets to 16.0 so SDK defaults can't drift the floor.
- `Config/Local.xcconfig` (gitignored) — `DEVELOPMENT_TEAM = VL2Z64A683`.
  Kept out of public history per user's instruction.
- `Config/Local.xcconfig.template` (committed) — placeholder seed for
  fresh checkouts. One-line `cp` instruction in the file header.
- `Config/{Debug,Release}.xcconfig` — added `#include? "Local.xcconfig"`
  and `#include? "../Pods/Target Support Files/Pods-EchoAir/Pods-EchoAir.{debug,release}.xcconfig"`.
  Optional includes mean the project resolves before either file
  exists; CocoaPods' base-config warning stays quiet.
- `EchoAir/Ble/KBeaconBridge.swift` — async/await wrapper around
  kbeaconlib2's closure callbacks. Encodes the §3.10 invariants
  explicitly: `syncUtcTime=false`, `readCommPara=true`,
  `readSensorPara=true`, `readTriggerPara=false`, `readSlotPara=false`,
  NormalOrder with cursor `0` initial, end-of-data via
  `INVALID_DATA_RECORD_POS`, 200-record pages. Every SDK call site is
  flagged `// TODO(spike): verify` — exact KBeacon selectors and
  response accessor names need confirmation against the installed pod
  on first compile.
- `EchoAir/Spike/{SpikeConfig,SpikeRunner,SpikeView}.swift` — debug-only
  spike harness, file-level `#if DEBUG` so it ships zero code in
  release. SpikeConfig holds placeholder MAC + password (engineer
  fills before running). SpikeRunner orchestrates scan → connect →
  read sensor info → paged record loop, logging the four pass
  criteria inline. SpikeView is a SwiftUI screen with a Run button
  and monospaced log pane.
- `EchoAir/App/ContentView.swift` — wrapped in `NavigationStack`,
  added `#if DEBUG` "Open BLE spike" NavigationLink. Release builds
  see only the placeholder card, byte-identical to phase 1.
- `.gitignore` — added `Config/Local.xcconfig` and
  `EchoAir.xcworkspace/`.

### Three flagged decisions worth revisiting

1. **`KBeaconBridge` selectors are unverified.** No `pod install`
   ran here, so every `beacon.connectEnhanced(...)`,
   `beacon.readSensorDataInfo(...)`, `beacon.readSensorRecord(...)`
   call is a best-effort shape from handoff §1's API surface — the
   exact parameter labels, callback signatures, and response
   accessor names (`rsp.records`, `rsp.readDataNextPos`) are
   guesses. The §3.10 *invariants* (cursor=0, NormalOrder,
   syncUtcTime=false, batch=200, INVALID_DATA_RECORD_POS as
   end-of-data sentinel, HTHumidity sensor type) are correct and
   must not be touched while fixing selector spelling. Sites are
   tagged `// TODO(spike): verify` for `grep` triage.
2. **CocoaPods + xcodegen interop via `#include?`.** The pods
   xcconfigs sit under our own `Config/{Debug,Release}.xcconfig`
   so our `API_BASE_URL` (and any future overrides) win over pod
   defaults. Trade-off: regenerating `project.yml`'s configFiles
   from scratch would lose the `#include?` lines — preserve them.
   If CocoaPods still emits the "base configuration" warning after
   first `pod install`, it's because the engineer hasn't run
   `xcodegen generate` against the post-pod state yet; harmless.
3. **Spike `discover(mac:)` is a stub that throws.** The full
   scan-then-find flow (KBeaconsMgr delegate, startScanning, MAC
   match, stopScanning) needs writing once the pod compiles. The
   continuation-bridging skeleton is in place — the engineer
   completes the delegate body. Keeping it as a throwing stub is
   deliberate: the spike will fail loudly on first run rather than
   appear to scan and hang silently.

### Next session pickup (for the iOS engineer, on his Mac)

1. `git pull` this branch.
2. `cp Config/Local.xcconfig.template Config/Local.xcconfig`, paste
   `VL2Z64A683` for `DEVELOPMENT_TEAM`. Confirm `git status` shows
   `Local.xcconfig` ignored.
3. `brew install xcodegen cocoapods` if not already; install Xcode
   15+ from the App Store. Confirm with `xcodebuild -version`.
4. `xcodegen generate`, then `pod install`. From here open
   `EchoAir.xcworkspace`, NOT the `.xcodeproj`.
5. Build the EchoAir scheme. First-compile errors in
   `EchoAir/Ble/KBeaconBridge.swift` and
   `EchoAir/Spike/SpikeRunner.swift` are *expected* — fix the SDK
   selectors against the installed `kbeaconlib2` 1.2.x. Cross-ref
   `KBeaconProDemo_Ios` for shape, but remember the demo uses
   `NewRecord` while we use `NormalOrder`. Do NOT change the §3.10
   invariants while fixing selectors.
6. Fill `EchoAir/Spike/SpikeConfig.swift` — test S23H MAC and the
   KBeacon password (same value as Android's
   `KBeaconIds.DEFAULT_PASSWORD`; ask the Android Echo Air builder).
   Do not commit either value. They're not gitignored, so just
   un-stage the file before pushing — or keep edits in a stash.
7. Run on a real iPhone (BLE doesn't work in simulator). Tap
   "Open BLE spike" → "Run spike". Confirm the log shows: connect
   OK, sensor info readable, paged reads succeeded with cursor=0,
   end-of-data hit `INVALID_DATA_RECORD_POS`, total record count
   matches the test device's expected fixtures.
8. Phase 2 is done when all four §3.10 invariants are confirmed.
   Report back with the spike log.

### Followup: spike credentials moved into `Local.xcconfig`

After review, the placeholder MAC + password in `SpikeConfig.swift`
were a tripwire for accidental commits. Moved both into the
already-gitignored `Config/Local.xcconfig`, surfaced to runtime via
`Info.plist` `$(VAR)` substitution (mirroring the existing
`API_BASE_URL` plumbing). All test secrets now live in one gitignored
place; `SpikeConfig.swift` reads them via
`Bundle.main.object(forInfoDictionaryKey:)` and the empty-string
fallback keeps the spike's "ABORT if empty" check intact. Empty
defaults in `Shared.xcconfig` mean the build settings always resolve
even on a fresh checkout, so the literal `$(SPIKE_DEVICE_MAC)` token
never leaks into a built Info.plist.

### Still deferred

- Phase 3+: UI, DTOs, networking, AWB validation, IATA lookup,
  locale system, persistence, BLE collection orchestrator,
  location capture, MPS rendering, finalize/stale logic, BT and
  location reactive gates, App Store cleanup pass.
- Marketing version trajectory (0.6.1 vs 1.0.0 — handoff §11).
- Persistence layer choice (Core Data vs SwiftData vs GRDB —
  handoff §11). Recommend GRDB unless a reason emerges.
- CocoaPods → vendored sources or SPM wrapper migration before
  App Store submission.

---

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
