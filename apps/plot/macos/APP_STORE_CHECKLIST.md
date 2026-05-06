# macOS App Store Submission Checklist

## ✅ Completed Items

### Sandboxing

- [x] App Sandbox enabled in both DebugProfile.entitlements and Release.entitlements
- [x] Project settings confirm sandbox is enabled
- [x] Entitlements properly configured for app capabilities

### Code Signing

- [x] Release build uses "Apple Development" for development/testing
- [x] CODE_SIGN_STYLE set to Automatic
- [x] DEVELOPMENT_TEAM configured (789MAH2W6P)
- [x] PRODUCT_BUNDLE_IDENTIFIER set (day.plot.app)

### Entitlements

- [x] `com.apple.security.app-sandbox` - App runs in sandbox
- [x] `com.apple.security.network.client` - Network access for API calls
- [x] `com.apple.security.network.server` - WebSocket support
- [x] `keychain-access-groups` - Google Sign In keychain access
- [x] `com.apple.developer.applesignin` - Sign in with Apple
- [x] `com.apple.security.cs.allow-jit` - Only in DebugProfile (correct for Flutter)

### App Metadata

- [x] Bundle Identifier: day.plot.app
- [x] Display Name: Plot
- [x] App Category: public.app-category.productivity
- [x] Copyright: Copyright © 2025 day.plot. All rights reserved.
- [x] Version: 1.0.0+169
- [x] Minimum macOS version: 14.0

## 🔄 Before Submission

### Code Signing for Distribution

- [ ] **CRITICAL**: When building for App Store submission, change CODE_SIGN_IDENTITY to "3rd Party Mac Developer Application" or use Xcode's Archive feature which handles this automatically
- [ ] Ensure you have a valid "Mac App Distribution" certificate in your Apple Developer account
- [ ] Ensure you have a valid "Mac Installer Distribution" certificate for pkg creation
- [ ] Verify provisioning profile is correct for App Store distribution

### App Store Connect Setup

- [ ] Create app record in App Store Connect (<https://appstoreconnect.apple.com>)
- [ ] Bundle ID matches: day.plot.app
- [ ] Configure app metadata (name, description, keywords, screenshots)
- [ ] Add app icon (at least 512x512 and 1024x1024)
- [ ] Prepare screenshots for required sizes:
  - 1280 x 800 pixels
  - 1440 x 900 pixels
  - 2560 x 1600 pixels
  - 2880 x 1800 pixels
- [ ] Set pricing and availability
- [ ] Configure age rating
- [ ] Add privacy policy URL (if collecting user data)

### Privacy & Compliance

- [ ] Review privacy policy requirements - app uses:
  - Network connections to Plot's API (Cloudflare Workers backed by GCP Cloud SQL)
  - OAuth authentication (Google, Apple, Microsoft)
  - PostHog analytics
  - User data storage
- [ ] Declare data collection in App Store Connect
- [ ] Update Info.plist with required usage descriptions if needed
- [ ] Ensure GDPR compliance if serving EU users
- [ ] Configure encryption export compliance

### Build Preparation

- [ ] Run `flutter pub run build_runner build --delete-conflicting-outputs`
- [ ] Run `flutter analyze` and fix all issues
- [ ] Run `flutter test` and ensure all tests pass
- [ ] Build release version: `flutter build macos --release`
- [ ] Test the release build thoroughly on a clean macOS installation
- [ ] Verify all features work with sandbox enabled
- [ ] Test on minimum supported macOS version (14.0)

### Archive & Upload

- [ ] Open Xcode project: `open apps/plot/macos/Runner.xcworkspace`
- [ ] Select "Any Mac" as the destination
- [ ] Product → Archive
- [ ] Validate the archive in Organizer
- [ ] Address any validation warnings/errors
- [ ] Upload to App Store Connect via Organizer
- [ ] Wait for processing to complete (can take 30+ minutes)

### Post-Upload

- [ ] Verify build appears in App Store Connect
- [ ] Check for any processing errors
- [ ] Complete remaining app information in App Store Connect
- [ ] Submit for App Review
- [ ] Respond to any App Review feedback promptly

## ⚠️ Important Notes

### Hardened Runtime

For App Store distribution, you may need to enable Hardened Runtime with specific exceptions:

- Go to Runner target → Signing & Capabilities
- Enable "Hardened Runtime"
- Add exceptions if needed:
  - Allow JIT Compilation (for Debug/Profile only)
  - Allow Unsigned Executable Memory (if needed by Flutter)
  - Allow DYLD Environment Variables (for Debug only)

### Network Server Entitlement

Your app currently requests `com.apple.security.network.server`. During review:

- Be prepared to explain why the app needs to accept incoming connections
- If only using WebSocket as a client, this may not be necessary
- Apple may ask for justification or reject if not clearly needed

### Common Rejection Reasons

- Incomplete metadata or poor quality screenshots
- Missing privacy policy
- App crashes or doesn't work as described
- Violates App Store Review Guidelines
- Insufficient justification for entitlements
- Hardcoded references to other platforms

### Testing Sandbox Compliance

Before submission, test with sandbox restrictions:

```bash
# Build with release configuration
flutter build macos --release

# Run with sandbox (simulates App Store environment)
sandbox-exec -f /System/Library/Sandbox/Profiles/bsd.sb \
  build/macos/Build/Products/Release/Plot.app/Contents/MacOS/Plot
```

### Notarization (If Distributing Outside App Store)

If also distributing outside the App Store:

```bash
# Create a signed and notarized build
flutter build macos --release
codesign --deep --force --verify --verbose --sign "Developer ID Application: <Your Name>" \
  build/macos/Build/Products/Release/Plot.app
ditto -c -k --keepParent build/macos/Build/Products/Release/Plot.app Plot.zip
xcrun notarytool submit Plot.zip --apple-id <email> --password <app-specific-password> --team-id <team-id>
```

## 📋 Pre-Submission Checklist

Run through this before clicking Submit:

- [ ] App has been tested on a clean Mac (not your development machine)
- [ ] All entitlements are justified and documented
- [ ] No debug code or test credentials in release build
- [ ] Privacy policy is accessible and accurate
- [ ] App icon meets requirements (no transparency, rounded corners, etc.)
- [ ] All screenshots are high quality and show actual app functionality
- [ ] App description is clear and accurate
- [ ] Keywords are relevant (max 100 characters)
- [ ] Contact information is current
- [ ] Support URL is functional
- [ ] Marketing URL (if provided) is functional
- [ ] All localizations are complete and accurate
- [ ] Version number follows semantic versioning
- [ ] Release notes are written (for updates)

## 🔗 Useful Links

- App Store Connect: <https://appstoreconnect.apple.com>
- App Store Review Guidelines: <https://developer.apple.com/app-store/review/guidelines/>
- Sandboxing Documentation: <https://developer.apple.com/documentation/security/app_sandbox>
- Entitlements Reference: <https://developer.apple.com/documentation/bundleresources/entitlements>
- Flutter macOS Deployment: <https://docs.flutter.dev/deployment/macos>
- Xcode Help: <https://help.apple.com/xcode/mac/current/#/dev442d7f2ca>

## 🆘 Troubleshooting

### "App is not properly signed"

- Verify CODE_SIGN_IDENTITY is set correctly for Release
- Check that certificates are valid in Keychain Access
- Try cleaning build folder: `flutter clean && flutter pub get`

### "Entitlement not allowed"

- Some entitlements require justification during review
- Check App Sandbox documentation for allowed combinations
- Remove any entitlements you don't actually need

### "App crashes on launch"

- Test with sandbox enabled (see Testing Sandbox Compliance above)
- Check for hardcoded paths that don't work in sandbox
- Verify all resources are properly bundled

### "Invalid Bundle"

- Ensure bundle identifier matches App Store Connect
- Check Info.plist for required keys
- Verify version numbers are correct format

### App Review Rejection

- Read rejection reason carefully
- Address all points raised
- Respond via Resolution Center
- Resubmit when ready (usually within 24 hours)
