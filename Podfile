platform :ios, '16.0'

inhibit_all_warnings!

project 'EchoAir.xcodeproj'   # ← Add this (XcodeGen generates this file)

target 'EchoAir' do

  use_frameworks! :linkage => :static

  pod 'kbeaconlib2', '~> 1.2'

end

post_install do |installer|

  installer.pods_project.targets.each do |t|
    t.build_configurations.each do |c|
      c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'
      c.build_settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
      c.build_settings['SWIFT_STRICT_CONCURRENCY'] = 'minimal'
    end
  end

end