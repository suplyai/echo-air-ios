# Echo Air — iOS

Native iOS port of [`suplyai/echo-air`](https://github.com/suplyai/echo-air).
Anchor: Android v0.6.1 (commit `c642866`). Same Suply backend, identical
wire-format DTOs, identical UX, identical vocabulary across en / es / zh / ja.

## Stack

- Swift + SwiftUI
- iOS 16.0+, iPhone only, portrait only
- Bundle IDs: `app.suply.echoair` (release), `app.suply.echoair.debug` (debug)
- Marketing version: 0.6.1 (parity with Android)
- Background mode: `bluetooth-central`
- KKM `kbeaconlib2` SDK via CocoaPods (added in phase 2)

The canonical invariants document lives in the **Android** repo at
`docs/ios-port-handoff.md`. Read it before changing DTOs, BLE constants,
locale system, MPS rendering, location capture, finalize/stale thresholds,
or privacy strings.

## Getting started

The Xcode project is generated from `project.yml` via
[xcodegen](https://github.com/yonaskolb/XcodeGen) — `EchoAir.xcodeproj/`
is gitignored. `Info.plist` and `Config/*.xcconfig` are the sources of
truth for app metadata and build settings.

```sh
brew install xcodegen
xcodegen generate
open EchoAir.xcodeproj
```

CocoaPods integration is added in phase 2 (KKM SDK + spike harness):

```sh
brew install cocoapods   # or: sudo gem install cocoapods
pod install
open EchoAir.xcworkspace
```

## Layout

```
project.yml                 # xcodegen spec (source of truth)
Config/                     # xcconfig — API_BASE_URL etc.
EchoAir/
  App/                      # SwiftUI App entry + root view
  Info.plist                # privacy strings, background modes, orientation
  Resources/
    PrivacyInfo.xcprivacy   # iOS 17+ privacy manifest
```

Feature directories (`Data/`, `Domain/`, `Ble/`, `Location/`,
`Persistence/`, `UI/…`) are added in their respective porting phases.
