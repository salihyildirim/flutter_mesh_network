#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_mesh_network.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_mesh_network'
  s.version          = '0.1.0'
  s.summary          = 'Flutter Mesh Network plugin for iOS — MultipeerConnectivity and BLE Peripheral.'
  s.description      = <<-DESC
Cross-platform mesh networking plugin. On iOS this wraps MultipeerConnectivity
(peer discovery, encrypted sessions, messaging) and CoreBluetooth peripheral
mode (GATT server, BLE advertising, chunked message assembly).
                       DESC
  s.homepage         = 'https://github.com/salihyildirim/flutter_mesh_network'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Salih Yildirim' => 'salihyildirimce@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'flutter_mesh_network_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end
