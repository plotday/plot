#!/bin/sh
# Raise the Flutter-generated Swift Package's iOS deployment floor to the app's
# deployment target so plugins that require iOS 15+ (e.g. firebase_core /
# firebase_messaging) build when launching straight from Xcode.
#
# Why this is needed:
#   Flutter's tooling only raises FlutterGeneratedPluginSwiftPackage's platform
#   floor in the `flutter build` / `flutter run` code path (see flutter_tools'
#   SwiftPackageManager.updateMinimumDeployment, which reads
#   IPHONEOS_DEPLOYMENT_TARGET). A bare `flutter pub get` — run by the worktree
#   setup hook, `pnpm install`, build_runner, or IDE tooling — regenerates the
#   package at Flutter's bare 13.0 default and does NOT raise it. Building from
#   Xcode (Cmd-R) uses the `xcode_backend.sh prepare` path, which likewise never
#   raises it. The result is a generated package pinned at iOS 13.0 depending on
#   Firebase products that require 15.0, and the build fails with:
#     "The package product 'firebase-messaging' requires minimum platform
#      version 15.0 for the iOS platform, but this target supports 13.0".
#
# This script re-applies the floor on every Xcode build (it is invoked from the
# Runner scheme's "Prepare Flutter Framework" pre-action, after prepare runs),
# mirroring exactly what `flutter build` would have done.
set -eu

PKG="${SRCROOT:-.}/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage/Package.swift"
FLOOR="${IPHONEOS_DEPLOYMENT_TARGET:-16.0}"

if [ ! -f "$PKG" ]; then
  # Package not generated yet (e.g. first configure pass) — nothing to do.
  exit 0
fi

# Replace the .iOS("<version>") floor with the project's deployment target.
/usr/bin/sed -i '' -E "s/\.iOS\(\"[0-9][0-9.]*\"\)/.iOS(\"${FLOOR}\")/" "$PKG"
