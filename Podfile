# Echo Air iOS — CocoaPods spec.
#
# Phase 2 brings in KKM's kbeaconlib2 BLE SDK for the spike harness.
# We're staying on `pod install` until the spike validates the four
# §3.10 invariants on real hardware; vendoring (or an SPM wrapper)
# happens before the App Store submission per handoff §1 / §11.
#
# The Xcode project is generated from `project.yml` via xcodegen, so
# `pod install` consumes a project that xcodegen has already produced.
# Run order on the engineer's Mac:
#   xcodegen generate
#   pod install
#   open EchoAir.xcworkspace        # NOT the .xcodeproj from here on

platform :ios, '16.0'
inhibit_all_warnings!

project 'EchoAir.xcodeproj'

target 'EchoAir' do
  use_frameworks!
  pod 'kbeaconlib2', '~> 1.2'
end

post_install do |installer|
  # Clamp pod deployment targets to the host floor so SDK defaults can't
  # silently drift the project minimum upward. Also disable User Script
  # Sandboxing on pod targets — CocoaPods' generated script phases
  # (rsync-based [CP] copy/embed steps) fail under the Xcode 15 sandbox
  # default. The host EchoAir target sets this in project.yml; this
  # block is the matching opt-out for Pods.xcodeproj, which xcodegen
  # has no visibility into.
  installer.pods_project.targets.each do |t|
    t.build_configurations.each do |c|
      c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'
      c.build_settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
    end
  end
end
