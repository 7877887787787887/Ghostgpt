#!/usr/bin/env ruby
require 'xcodeproj'
require 'fileutils'

project_path = 'ios/App/App.xcodeproj'
project = Xcodeproj::Project.open(project_path)
app = project.targets.find { |target| target.name == 'App' }
abort 'Missing generated App target' unless app
abort 'UI test target already exists' if project.targets.any? { |target| target.name == 'GhostGPTUITests' }

FileUtils.mkdir_p('ios/App/GhostGPTUITests')
FileUtils.cp('ios-native/GhostGPTUITests.swift', 'ios/App/GhostGPTUITests/GhostGPTUITests.swift')
target = project.new_target(:ui_test_bundle, 'GhostGPTUITests', :ios, '17.0')
target.add_dependency(app)
group = project.main_group.new_group('GhostGPTUITests', 'GhostGPTUITests')
target.source_build_phase.add_file_reference(group.new_file('GhostGPTUITests.swift'))
target.build_configurations.each do |config|
  config.build_settings.merge!({
    'PRODUCT_BUNDLE_IDENTIFIER' => 'io.corelo.ghostgpt.uitests',
    'GENERATE_INFOPLIST_FILE' => 'YES',
    'SWIFT_VERSION' => '5.0',
    'TEST_TARGET_NAME' => 'App',
    'TARGETED_DEVICE_FAMILY' => '1,2',
    'CODE_SIGNING_ALLOWED' => 'NO',
    'CODE_SIGNING_REQUIRED' => 'NO'
  })
end
project.root_object.attributes['TargetAttributes'] ||= {}
project.root_object.attributes['TargetAttributes'][target.uuid] = { 'TestTargetID' => app.uuid }
project.save
# Once a shared scheme exists, do not rely on Xcode's implicit App scheme.
app_scheme = Xcodeproj::XCScheme.new
app_scheme.configure_with_targets(app, nil, launch_target: true)
app_scheme.save_as(project_path, 'App', true)
scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(app, target, launch_target: true)
scheme.save_as(project_path, 'GhostGPTUITests', true)
puts 'Created shared GhostGPTUITests scheme with UI test target'
