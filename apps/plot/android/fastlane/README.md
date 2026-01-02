fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## Android

### android build

```sh
[bundle exec] fastlane android build
```

Build the Android app (App Bundle)

### android build_apk

```sh
[bundle exec] fastlane android build_apk
```

Build APK

### android screenshots

```sh
[bundle exec] fastlane android screenshots
```

Generate screenshots for Play Store

### android beta

```sh
[bundle exec] fastlane android beta
```

Upload a new beta version to the Google Play (Internal Testing)

### android metadata

```sh
[bundle exec] fastlane android metadata
```

Upload metadata to Google Play Console

### android promote_to_production

```sh
[bundle exec] fastlane android promote_to_production
```

Promote beta to production

### android release

```sh
[bundle exec] fastlane android release
```

Deploy a new version to the Google Play (Production)

### android test

```sh
[bundle exec] fastlane android test
```

Run tests

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
