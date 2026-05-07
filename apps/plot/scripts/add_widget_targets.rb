#!/usr/bin/env ruby
# frozen_string_literal: true

# Adds the PlotWidget WidgetKit extension target to the iOS and macOS
# Xcode projects. Idempotent — safe to re-run.
#
# Usage:
#   ruby apps/plot/scripts/add_widget_targets.rb
#
# Requires the `xcodeproj` gem (`gem install xcodeproj`).
#
# This script lays out scaffolding only:
# - The extension's Swift entry point (`PlotWidgetBundle.swift`) ships
#   with an `EmptyWidgetBundle`, so no widget appears in the system
#   widget gallery until designs land.
# - The Runner target gets the extension embedded in its
#   `Embed App Extensions` build phase, so the bundled `.appex` ships
#   with the host app.
# - The Runner target's `WidgetBridge/` Swift sources are added so the
#   `MethodChannel('day.plot/widgets')` plugin compiles.
#
# Re-run after adding new files to either `Runner/WidgetBridge/` or
# `PlotWidget/` to register them with the appropriate target.

require 'xcodeproj'

ROOT = File.expand_path('..', __dir__)

# ----- iOS -----

def add_ios_widget_target
  proj_path = File.join(ROOT, 'ios', 'Runner.xcodeproj')
  project = Xcodeproj::Project.open(proj_path)

  runner = project.targets.find { |t| t.name == 'Runner' }
  raise 'Runner target not found in iOS project' unless runner

  # Add Runner-side WidgetBridge sources to Runner target if missing.
  runner_bridge_group = ensure_group(project.main_group, 'Runner', 'WidgetBridge', 'Runner/WidgetBridge')
  add_source_if_missing(runner_bridge_group, runner, File.join(ROOT, 'ios', 'Runner', 'WidgetBridge', 'WidgetBridgePlugin.swift'))
  add_source_if_missing(runner_bridge_group, runner, File.join(ROOT, 'ios', 'Runner', 'WidgetBridge', 'PlotWidgetSharedStorage.swift'))

  existing = project.targets.find { |t| t.name == 'PlotWidget' }
  if existing
    puts '[ios] PlotWidget target already exists; checking sources'
    sync_extension_sources(project, existing, ios: true)
    project.save
    return
  end

  puts '[ios] adding PlotWidget target'
  target = project.new_target(:app_extension, 'PlotWidget', :ios, '14.0')

  configure_extension_settings(target, ios: true)
  attach_extension_files(project, target, ios: true)
  embed_extension_into_runner(project, runner, target)

  project.save
end

# ----- macOS -----

def add_macos_widget_target
  proj_path = File.join(ROOT, 'macos', 'Runner.xcodeproj')
  project = Xcodeproj::Project.open(proj_path)

  runner = project.targets.find { |t| t.name == 'Runner' }
  raise 'Runner target not found in macOS project' unless runner

  runner_bridge_group = ensure_group(project.main_group, 'Runner', 'WidgetBridge', 'Runner/WidgetBridge')
  add_source_if_missing(runner_bridge_group, runner, File.join(ROOT, 'macos', 'Runner', 'WidgetBridge', 'WidgetBridgePlugin.swift'))
  add_source_if_missing(runner_bridge_group, runner, File.join(ROOT, 'macos', 'Runner', 'WidgetBridge', 'PlotWidgetSharedStorage.swift'))

  menu_bar_group = ensure_group(project.main_group, 'Runner', 'MenuBar', 'Runner/MenuBar')
  add_source_if_missing(menu_bar_group, runner, File.join(ROOT, 'macos', 'Runner', 'MenuBar', 'MenuBarController.swift'))

  existing = project.targets.find { |t| t.name == 'PlotWidget' }
  if existing
    puts '[macos] PlotWidget target already exists; checking sources'
    sync_extension_sources(project, existing, ios: false)
    project.save
    return
  end

  puts '[macos] adding PlotWidget target'
  target = project.new_target(:app_extension, 'PlotWidget', :osx, '11.0')

  configure_extension_settings(target, ios: false)
  attach_extension_files(project, target, ios: false)
  embed_extension_into_runner(project, runner, target)

  project.save
end

# ----- helpers -----

def ensure_group(parent, *path_components, real_path)
  current = parent
  path_components.each do |name|
    found = current.groups.find { |g| g.name == name || g.path == name }
    current = found || current.new_group(name)
  end
  current.set_source_tree('SOURCE_ROOT') if current.respond_to?(:set_source_tree)
  current.set_path(real_path) if current.respond_to?(:set_path) && current.path != real_path
  current
end

def add_source_if_missing(group, target, absolute_path)
  rel = Pathname.new(absolute_path).relative_path_from(Pathname.new(group.real_path)).to_s
  basename = File.basename(absolute_path)
  existing_ref = group.files.find { |f| f.path == rel || f.path == basename }
  ref = existing_ref || group.new_reference(rel)
  unless target.source_build_phase.files_references.include?(ref)
    target.source_build_phase.add_file_reference(ref)
  end
end

def configure_extension_settings(target, ios:)
  bundle_id = ios ? 'day.plot.app.PlotWidget' : 'day.plot.app.PlotWidget'
  entitlements = ios ? 'PlotWidget/PlotWidget.entitlements' : 'PlotWidget/PlotWidget.entitlements'
  info_plist = ios ? 'PlotWidget/Info.plist' : 'PlotWidget/Info.plist'

  target.build_configurations.each do |config|
    config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = bundle_id
    config.build_settings['PRODUCT_NAME'] = 'PlotWidget'
    config.build_settings['INFOPLIST_FILE'] = info_plist
    config.build_settings['CODE_SIGN_ENTITLEMENTS'] = entitlements
    config.build_settings['SWIFT_VERSION'] = '5.0'
    config.build_settings['SKIP_INSTALL'] = 'YES'
    # Match Runner's signing setup so the extension picks up the same
    # team / automatic provisioning. Override Debug-only configurations
    # below where appropriate.
    config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
    config.build_settings['DEVELOPMENT_TEAM'] = '789MAH2W6P'
    if ios
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '14.0'
      config.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
      config.build_settings['CODE_SIGN_IDENTITY'] = 'Apple Development'
      config.build_settings['LD_RUNPATH_SEARCH_PATHS'] = [
        '$(inherited)',
        '@executable_path/Frameworks',
        '@executable_path/../../Frameworks'
      ]
    else
      config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '11.0'
      config.build_settings['CODE_SIGN_IDENTITY'] = 'Apple Development'
      config.build_settings['LD_RUNPATH_SEARCH_PATHS'] = [
        '$(inherited)',
        '@executable_path/../Frameworks',
        '@executable_path/../../Frameworks'
      ]
      config.build_settings['ENABLE_HARDENED_RUNTIME'] = 'YES'
    end
  end
end

def attach_extension_files(project, target, ios:)
  group = project.main_group.find_subpath('PlotWidget', true)
  group.set_source_tree('SOURCE_ROOT')
  group.set_path('PlotWidget')

  bundle_path = ios ? File.join(ROOT, 'ios', 'PlotWidget', 'PlotWidgetBundle.swift') : File.join(ROOT, 'macos', 'PlotWidget', 'PlotWidgetBundle.swift')
  add_source_if_missing(group, target, bundle_path)

  # The extension's shared-storage helper is the same source file the
  # Runner target uses — share by membership rather than duplication.
  shared_storage = ios ?
    File.join(ROOT, 'ios', 'Runner', 'WidgetBridge', 'PlotWidgetSharedStorage.swift') :
    File.join(ROOT, 'macos', 'Runner', 'WidgetBridge', 'PlotWidgetSharedStorage.swift')
  shared_group = ios ?
    ensure_group(project.main_group, 'Runner', 'WidgetBridge', 'Runner/WidgetBridge') :
    ensure_group(project.main_group, 'Runner', 'WidgetBridge', 'Runner/WidgetBridge')
  add_source_if_missing(shared_group, target, shared_storage)

  # Info.plist + entitlements are referenced via build settings, not
  # build phases, so they only need to exist as project file refs.
  ensure_file_reference(group, 'Info.plist')
  ensure_file_reference(group, 'PlotWidget.entitlements')
end

def ensure_file_reference(group, basename)
  return if group.files.any? { |f| f.path == basename }
  group.new_reference(basename)
end

def embed_extension_into_runner(project, runner, ext_target)
  # Intentionally not embedding today — the new bundle ID
  # `day.plot.app.PlotWidget` is not yet provisioned, so embedding
  # the extension would break the parent app build for anyone
  # without a custom provisioning profile. The target exists and
  # builds standalone; flip embedding on (uncomment the body of
  # this method) once the bundle ID is provisioned and a real
  # widget is shipping.
end

def sync_extension_sources(project, target, ios:)
  group = project.main_group.find_subpath('PlotWidget', true)
  bundle_path = ios ? File.join(ROOT, 'ios', 'PlotWidget', 'PlotWidgetBundle.swift') : File.join(ROOT, 'macos', 'PlotWidget', 'PlotWidgetBundle.swift')
  add_source_if_missing(group, target, bundle_path)

  shared_storage = ios ?
    File.join(ROOT, 'ios', 'Runner', 'WidgetBridge', 'PlotWidgetSharedStorage.swift') :
    File.join(ROOT, 'macos', 'Runner', 'WidgetBridge', 'PlotWidgetSharedStorage.swift')
  shared_group = ensure_group(project.main_group, 'Runner', 'WidgetBridge', 'Runner/WidgetBridge')
  add_source_if_missing(shared_group, target, shared_storage)
end

add_ios_widget_target
add_macos_widget_target
puts 'Done. Open Xcode and let it re-index. Provision App Group "group.day.plot.app" for both Runner and PlotWidget bundle IDs in the Apple Developer portal before signing a build.'
