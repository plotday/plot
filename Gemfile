source "https://rubygems.org"

# Fastlane for build automation and app store publishing
gem "fastlane", "~> 2.220"

# Fastlane plugins
plugins_path = File.join(File.dirname(__FILE__), 'fastlane', 'Pluginfile')
eval_gemfile(plugins_path) if File.exist?(plugins_path)
