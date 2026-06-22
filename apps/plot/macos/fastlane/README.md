fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## Mac

### mac build

```sh
[bundle exec] fastlane mac build
```

Build the macOS app

### mac build_dmg

```sh
[bundle exec] fastlane mac build_dmg
```

Build DMG for direct distribution

### mac build_mas

```sh
[bundle exec] fastlane mac build_mas
```

Build and archive for Mac App Store

### mac screenshots

```sh
[bundle exec] fastlane mac screenshots
```

Generate screenshots for Mac App Store

### mac beta

```sh
[bundle exec] fastlane mac beta
```

Upload a new beta build to TestFlight (Mac)

### mac metadata

```sh
[bundle exec] fastlane mac metadata
```

Upload metadata and screenshots to Mac App Store Connect

### mac release_mas

```sh
[bundle exec] fastlane mac release_mas
```

Deploy a new version to the Mac App Store

### mac release_dmg

```sh
[bundle exec] fastlane mac release_dmg
```

Create GitHub release with DMG (integrates with existing workflow)

### mac test

```sh
[bundle exec] fastlane mac test
```

Run tests

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
