# Uncomment the next line to define a global platform for your project
platform :ios, '10.3'

target 'SignalRSwift' do
  # Comment the next line if you're not using Swift and don't want to use dynamic frameworks
  use_frameworks!
  
  # Pods for SignalR-Swift
  pod 'Alamofire', '~> 4.8.2'
  pod 'Starscream', '~> 3.1.0'

  target 'SignalR-SwiftTests' do
    inherit! :search_paths
    # Pods for testing
    pod 'Quick', '~> 2.1'
    pod 'Nimble', '~> 8.0'
    pod 'Mockit', '1.5'
  end

end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    if target.name == 'Mockit'
      target.build_configurations.each do |config|
        config.build_settings['SWIFT_VERSION'] = '5.0'
      end
    end
  end
end
