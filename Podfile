platform :ios, '16.0'

inhibit_all_warnings!

# IMPORTANT: XcodeGen already generates project
# so we do NOT strictly bind to xcodeproj here

target 'EchoAir' do

  # FIX: stable modern CocoaPods linking for CI
  use_frameworks! :linkage => :static

  pod 'kbeaconlib2', '~> 1.2'

end

post_install do |installer|

  installer.pods_project.targets.each do |t|
    t.build_configurations.each do |c|

      # keep deployment stable
      c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'

      # CI FIX: prevents Xcode 15/16 script sandbox crashes
      c.build_settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'

      # IMPORTANT: avoids Swift 6 strict CI failures in pods
      c.build_settings['SWIFT_STRICT_CONCURRENCY'] = 'minimal'

    end
  end

end