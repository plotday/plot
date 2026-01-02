# Fastlane Setup for Plot

This directory contains Fastlane configuration for automating builds, screenshots, and app store deployments across all Plot platforms (iOS, macOS, Android).

## Overview

Fastlane is set up for:

- **Screenshot generation** for all platforms and app stores
- **App Store publishing** (TestFlight, App Store Connect, Play Store, Mac App Store)
- **Metadata management** (descriptions, keywords, release notes)
- **Build automation** (local builds for testing and releases)

## Installation

1. **Install Ruby dependencies:**

   ```bash
   # From the project root
   bundle install
   ```

2. **Install Fastlane (if not already installed):**

   ```bash
   gem install fastlane
   ```

## Platform-Specific Setup

### iOS

**Location:** `apps/plot/ios/fastlane/`

**Prerequisites:**

- Xcode installed with command line tools
- Apple Developer account
- Set `APPLE_ID` environment variable (your Apple ID email)

**Available Lanes:**

```bash
cd apps/plot/ios
bundle exec fastlane build          # Build the app
bundle exec fastlane archive        # Build and archive for distribution
bundle exec fastlane screenshots    # Generate App Store screenshots
bundle exec fastlane beta           # Upload to TestFlight
bundle exec fastlane metadata       # Upload metadata to App Store Connect
bundle exec fastlane release        # Submit to App Store
bundle exec fastlane test           # Run tests
```

**Configuration Files:**

- `Appfile` - App identifier, Apple ID, Team ID
- `Fastfile` - Lane definitions
- `Snapfile` - Screenshot configuration
- `metadata/en-US/` - App Store metadata

### macOS

**Location:** `apps/plot/macos/fastlane/`

**Prerequisites:**

- Xcode installed with command line tools
- Apple Developer account
- Set `APPLE_ID` environment variable
- (Optional) Set `MAC_INSTALLER_CERT_NAME` for Mac App Store builds

**Available Lanes:**

```bash
cd apps/plot/macos
bundle exec fastlane build          # Build the app
bundle exec fastlane build_dmg      # Build for DMG distribution
bundle exec fastlane build_mas      # Build for Mac App Store
bundle exec fastlane screenshots    # Generate screenshots
bundle exec fastlane beta           # Upload to TestFlight (Mac)
bundle exec fastlane metadata       # Upload metadata to Mac App Store
bundle exec fastlane release_mas    # Submit to Mac App Store
bundle exec fastlane release_dmg    # Create GitHub release (placeholder)
bundle exec fastlane test           # Run tests
```

**Notes:**

- The `build_dmg` lane builds the app; DMG packaging and notarization is handled by the existing GitHub Actions workflow
- The `build_mas` lane creates builds for Mac App Store distribution
- Both distribution methods (DMG and Mac App Store) are supported

**Configuration Files:**

- `Appfile` - App identifier, Apple ID, Team ID
- `Fastfile` - Lane definitions
- `Snapfile` - Screenshot configuration
- `metadata/en-US/` - Mac App Store metadata

### Android

**Location:** `apps/plot/android/fastlane/`

**Prerequisites:**

- Android SDK installed
- Flutter installed and configured
- Google Play Console API credentials (JSON key file)
- Set keystore properties in `android/key.properties`

**Available Lanes:**

```bash
cd apps/plot/android
bundle exec fastlane build                    # Build App Bundle
bundle exec fastlane build_apk                # Build APK
bundle exec fastlane screenshots              # Generate Play Store screenshots
bundle exec fastlane beta                     # Upload to Internal Testing
bundle exec fastlane metadata                 # Upload metadata to Play Console
bundle exec fastlane promote_to_production    # Promote beta to production
bundle exec fastlane release                  # Upload to Production (as draft)
bundle exec fastlane test                     # Run tests
```

**Configuration Files:**

- `Appfile` - Package name, JSON key file path
- `Fastfile` - Lane definitions
- `Screengrabfile` - Screenshot configuration
- `metadata/android/en-US/` - Play Store metadata

## Environment Variables

Set these environment variables for automated builds:

```bash
# Apple/iOS/macOS
export APPLE_ID="your.email@example.com"
export FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx"
export MAC_INSTALLER_CERT_NAME="3rd Party Mac Developer Installer"  # Optional, for Mac App Store

# Android
export JSON_KEY_FILE="/path/to/google-play-api-key.json"
```

For local development, you can create a `.env` file in the project root (already gitignored):

```bash
APPLE_ID=your.email@example.com
FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD=xxxx-xxxx-xxxx-xxxx
JSON_KEY_FILE=/path/to/google-play-api-key.json
```

## Screenshot Generation

### iOS & macOS (Snapshot)

Screenshots are generated using Fastlane Snapshot, which requires UI tests:

1. **Create UI tests** that navigate to screens you want to capture
2. **Add snapshot calls** in your UI tests:

   ```swift
   snapshot("ScreenName")
   ```

3. **Run screenshot generation:**

   ```bash
   bundle exec fastlane screenshots
   ```

Screenshots will be saved to `fastlane/screenshots/` organized by device and locale.

### Android (Screengrab)

Screenshots are generated using Fastlane Screengrab, which requires instrumentation tests:

1. **Add Screengrab to your test dependencies** (already configured)
2. **Create instrumentation tests** with screenshot capture:

   ```kotlin
   Screengrab.screenshot("screen_name")
   ```

3. **Run screenshot generation:**

   ```bash
   bundle exec fastlane screenshots
   ```

Screenshots will be saved to `fastlane/screenshots/` organized by device and locale.

## Metadata Management

All app store metadata is version-controlled in the `metadata/` directories:

### iOS/macOS Metadata Files

- `name.txt` - App name
- `subtitle.txt` - Short description (30 chars)
- `description.txt` - Full description
- `keywords.txt` - Comma-separated keywords (100 chars)
- `marketing_url.txt` - Marketing website URL
- `privacy_url.txt` - Privacy policy URL
- `support_url.txt` - Support website URL
- `promotional_text.txt` - Promotional text (170 chars)
- `release_notes.txt` - What's new in this version

### Android Metadata Files

- `title.txt` - App title (50 chars max)
- `short_description.txt` - Short description (80 chars max)
- `full_description.txt` - Full description (4000 chars max)

### Updating Metadata

1. Edit the text files in `metadata/[locale]/`
2. Upload to app stores:

   ```bash
   bundle exec fastlane metadata
   ```

## Common Workflows

### Releasing a New Version

#### iOS

```bash
cd apps/plot/ios

# 1. Update version in pubspec.yaml (done at project level)
# 2. Update release notes
echo "New features and improvements" > fastlane/metadata/en-US/release_notes.txt

# 3. Build and submit to TestFlight
bundle exec fastlane beta

# 4. After testing, submit to App Store
bundle exec fastlane release
```

#### macOS (Mac App Store)

```bash
cd apps/plot/macos

# 1. Update version in pubspec.yaml
# 2. Update release notes
echo "New features and improvements" > fastlane/metadata/en-US/release_notes.txt

# 3. Build and submit to TestFlight
bundle exec fastlane beta

# 4. After testing, submit to Mac App Store
bundle exec fastlane release_mas
```

#### macOS (DMG Distribution)

```bash
cd apps/plot/macos

# 1. Build the app
bundle exec fastlane build_dmg

# 2. DMG packaging, signing, and notarization handled by GitHub Actions
# See .github/workflows/build-macos.yml
```

#### Android

```bash
cd apps/plot/android

# 1. Update version in pubspec.yaml
# 2. Build and upload to internal testing
bundle exec fastlane beta

# 3. After testing, promote to production
bundle exec fastlane promote_to_production

# Or upload directly to production (as draft):
bundle exec fastlane release
```

### Generating Screenshots

```bash
# iOS
cd apps/plot/ios && bundle exec fastlane screenshots

# macOS
cd apps/plot/macos && bundle exec fastlane screenshots

# Android
cd apps/plot/android && bundle exec fastlane screenshots
```

## CI/CD Integration (Future)

While Fastlane is currently configured for local use, it can be integrated into GitHub Actions workflows:

```yaml
# Example: .github/workflows/deploy-ios.yml
- name: Install Fastlane
  run: bundle install

- name: Deploy to TestFlight
  run: cd apps/plot/ios && bundle exec fastlane beta
  env:
    APPLE_ID: ${{ secrets.APPLE_ID }}
    FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD: ${{ secrets.FASTLANE_PASSWORD }}
```

## Troubleshooting

### iOS/macOS: "No profiles for 'day.plot.app' were found"

- Ensure you're logged in to Xcode with your Apple Developer account
- Run `fastlane match` if using certificate management (not currently configured)

### Android: "No JSON key file found"

- Ensure `JSON_KEY_FILE` environment variable points to your Google Play API credentials
- Or set `json_key_file` in `android/fastlane/Appfile`

### Screenshots: "Could not find UI tests"

- Ensure UI/instrumentation tests are created for your app
- Check that the scheme/package name matches in Snapfile/Screengrabfile

### General: "Bundle install fails"

- Ensure you have a compatible Ruby version (2.7+)
- Try running `bundle update`

## Documentation

- [Fastlane Documentation](https://docs.fastlane.tools/)
- [Snapshot Documentation](https://docs.fastlane.tools/actions/snapshot/)
- [Screengrab Documentation](https://docs.fastlane.tools/actions/screengrab/)
- [App Store Metadata](https://docs.fastlane.tools/actions/upload_to_app_store/)
- [Play Store Metadata](https://docs.fastlane.tools/actions/upload_to_play_store/)

## Support

For questions or issues with Fastlane setup, see:

- Project README
- Fastlane documentation
- [Fastlane community](https://github.com/fastlane/fastlane/discussions)
