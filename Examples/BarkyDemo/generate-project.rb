#!/usr/bin/env ruby
# Optional regeneration helper. The generated project is checked in; no Ruby dependency is needed to open it.
require 'xcodeproj'

root = File.expand_path(__dir__)
project = Xcodeproj::Project.new(File.join(root, 'BarkyDemo.xcodeproj'))
app = project.new_target(:application, 'BarkyDemo', :ios, '16.0')
tests = project.new_target(:ui_test_bundle, 'BarkyDemoUITests', :ios, '16.0')
tests.add_dependency(app)
group = project.main_group.new_group('Demo')
%w[BarkyDemoApp.swift DemoProtocol.swift].each { |file| app.source_build_phase.add_file_reference(group.new_file(file)) }
tests.source_build_phase.add_file_reference(group.new_file('UITests/ChatUITests.swift'))

package = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
package.relative_path = '../..'
project.root_object.package_references << package
product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
product.package = package
product.product_name = 'Barky'
app.package_product_dependencies << product
build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
build_file.product_ref = product
app.frameworks_build_phase.files << build_file

[app, tests].each do |target|
  target.build_configurations.each do |config|
    config.build_settings.merge!({
      'SWIFT_VERSION' => '5.0', 'GENERATE_INFOPLIST_FILE' => 'YES',
      'TARGETED_DEVICE_FAMILY' => '1,2', 'CODE_SIGN_STYLE' => 'Automatic',
      'PRODUCT_BUNDLE_IDENTIFIER' => "app.barky.#{target.name}",
      'MARKETING_VERSION' => '0.1.0', 'CURRENT_PROJECT_VERSION' => '1'
    })
  end
end
app.build_configurations.each do |config|
  config.build_settings['INFOPLIST_KEY_UILaunchScreen_Generation'] = 'YES'
  config.build_settings['INFOPLIST_KEY_UIApplicationSceneManifest_Generation'] = 'YES'
  config.build_settings['INFOPLIST_FILE'] = 'Info.plist'
  config.build_settings['INFOPLIST_KEY_UISupportedInterfaceOrientations'] = 'UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight'
end
tests.build_configurations.each { |config| config.build_settings['TEST_TARGET_NAME'] = 'BarkyDemo' }
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.set_launch_target(app)
scheme.add_test_target(tests)
scheme.save_as(project.path, 'BarkyDemo', true)
