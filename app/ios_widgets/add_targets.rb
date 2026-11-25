# Adds the TetraWidgets extension (Live Activity + home screen widget) to the
# generated Xcode project and the channel plugin to Runner. Idempotent.
# Usage: ruby add_targets.rb <ios dir> <version> <build number>
require 'xcodeproj'

ios, version, build = ARGV
project = Xcodeproj::Project.open(File.join(ios, 'Runner.xcodeproj'))
if project.targets.any? { |t| t.name == 'TetraWidgets' }
  puts 'TetraWidgets already in the project'
  exit 0
end

runner = project.targets.find { |t| t.name == 'Runner' } or abort('no Runner target')
app_id = runner.build_configurations.map { |c| c.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] }.compact.first or abort('no bundle id')
team = runner.build_configurations.map { |c| c.build_settings['DEVELOPMENT_TEAM'] }.compact.first

# Runner: shared model + channel plugin, entitlements (App Group), iOS 15.
shared = project.main_group.new_group('Shared', 'Shared')
shared_ref = shared.new_reference('TetraShared.swift')
runner_group = project.main_group['Runner'] or abort('no Runner group')
plugin_ref = runner_group.new_reference('TetraLivePlugin.swift')
runner_group.new_reference('Runner.entitlements')
runner.source_build_phase.add_file_reference(shared_ref)
runner.source_build_phase.add_file_reference(plugin_ref)
runner.build_configurations.each do |c|
  c.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
  c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
end

# The extension target.
ext = project.new_target(:app_extension, 'TetraWidgets', :ios, '16.2', nil, :swift)
existing = ext.build_configurations.map(&:name)
runner.build_configurations.each do |rc|
  next if existing.include?(rc.name)
  ext.add_build_configuration(rc.name, rc.name == 'Debug' ? :debug : :release)
end
group = project.main_group.new_group('TetraWidgets', 'TetraWidgets')
sources = %w[TetraWidgetsBundle.swift TetraLiveActivity.swift StatusWidget.swift].map { |f| group.new_reference(f) }
group.new_reference('Info.plist')
group.new_reference('TetraWidgets.entitlements')
ext.add_file_references(sources)
ext.source_build_phase.add_file_reference(shared_ref)
ext.build_configurations.each do |c|
  s = c.build_settings
  s['PRODUCT_NAME'] = '$(TARGET_NAME)'
  s['PRODUCT_BUNDLE_IDENTIFIER'] = "#{app_id}.TetraWidgets"
  s['INFOPLIST_FILE'] = 'TetraWidgets/Info.plist'
  s['GENERATE_INFOPLIST_FILE'] = 'NO'
  s['CODE_SIGN_ENTITLEMENTS'] = 'TetraWidgets/TetraWidgets.entitlements'
  s['SWIFT_VERSION'] = '5.0'
  s['TARGETED_DEVICE_FAMILY'] = '1,2'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = '16.2'
  s['SKIP_INSTALL'] = 'YES'
  s['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
  s['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks']
  s['MARKETING_VERSION'] = version
  s['CURRENT_PROJECT_VERSION'] = build
  s['DEVELOPMENT_TEAM'] = team if team
  s['SWIFT_OPTIMIZATION_LEVEL'] = c.name == 'Debug' ? '-Onone' : '-O'
end

# Embed the extension in the app. The copy phase goes right after the
# resources, before Flutter's "Thin Binary" script, or Xcode reports a cycle.
embed = runner.new_copy_files_build_phase('Embed Foundation Extensions')
embed.symbol_dst_subfolder_spec = :plug_ins
embed.add_file_reference(ext.product_reference, true).settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
runner.build_phases.delete(embed)
runner.build_phases.insert(runner.build_phases.index(runner.resources_build_phase) + 1, embed)
runner.add_dependency(ext)

project.save
puts "TetraWidgets added (#{app_id}.TetraWidgets, #{version} (#{build}))"
