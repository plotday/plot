---
name: patch-releases
description: Merge fixes from main into release branches and trigger Shorebird OTA patch workflows. Finds recent releases, handles native compatibility, and runs CI.
---

# Patch Releases

Merge fixes from main into Shorebird release branches and trigger OTA patch workflows. Handles native compatibility analysis, auto-reverts unpatchable changes, and triggers CI.

## Invocation

The user may invoke this skill directly (`/patch-releases`) or describe what they want:

- "Patch the latest releases"
- "Patch only macos"
- "Patch macos/1.1.6+322 excluding changes to lib/notifications/"
- "Patch the latest releases, exclude commit abc1234"

Parse the user's intent to extract:
- **Platforms**: ios, android, macos, windows (default: all)
- **Versions**: specific versions or "latest N" (default: latest 2 per platform)
- **Exclusions**: file paths, directories, or commit hashes to exclude

## Step 1: Discover Releases

Find the releases to patch:

```bash
# Fetch all tags
git fetch --tags --force

# List platform release tags sorted by build number
git tag -l 'ios/*' 'android/*' 'macos/*' 'windows/*'
```

For each platform the user wants to patch:
1. Collect all `{platform}/{version}` tags
2. Sort by build number (the `+NNN` suffix) descending
3. Take the top 2 (or user-specified count/versions)
4. Verify `release/{version}` branch exists — skip with warning if not
5. Deduplicate: if multiple platforms share a version, merge work happens once on the shared `release/{version}` branch

**Present a summary and wait for confirmation:**

```
Releases to patch:
  release/1.1.6+325  →  ios, android, macos, windows  (47 commits behind main)
  release/1.1.6+322  →  macos                          (89 commits behind main)

Proceed?
```

Do NOT modify any branches until the user confirms.

## Step 2: For Each Release Branch

Process each release branch independently. Older releases may have more native divergence.

### 2a. Merge Main

```bash
git checkout release/{version}
git merge main --no-edit
```

If there are merge conflicts, stop and present them to the user.

### 2b. Analyze Native Compatibility

Diff between the original release commit and the merge result to detect unpatchable native changes. The release commit is the one tagged with the version bump (find it via `git log --oneline release/{version} | grep "Bump version to {version}"` or use the merge base).

**Files to diff:**

| File/Pattern | What it detects |
|---|---|
| `apps/plot/pubspec.yaml` dependencies section | New packages not in release, removed packages |
| `apps/plot/pubspec.yaml` dependency_overrides | Changed native asset paths |
| `apps/plot/ios/Podfile.lock` | iOS pod version changes |
| `apps/plot/macos/Podfile.lock` | macOS pod version changes |
| `apps/plot/ios/Runner/Info.plist` | New URL schemes, permissions |
| `apps/plot/macos/Runner/Info.plist` | New URL schemes, permissions |
| `apps/plot/android/app/build.gradle` | New native dependencies |
| `apps/plot/android/gradle.properties` | Android config changes |
| `apps/plot/ios/Runner/*.entitlements` | New capabilities |

**Classification:**

- **High risk — new native plugin**: A dependency in pubspec.yaml that doesn't exist at the release commit (e.g., `flutter_local_notifications` added). Must revert all Dart code that depends on it.
- **Medium risk — platform config**: New entries in Info.plist, entitlements, build.gradle that aren't in the release binary. Flag but don't revert — affected features won't work but won't crash.
- **Low risk — native SDK bump**: Pod or native dependency version change (e.g., PostHog 3.43→3.48). Dart API usually backwards-compatible. Flag but proceed.
- **Safe — pure Dart**: New Dart-only packages (e.g., `re_highlight`), Dart dependency upgrades. No action needed.

### 2c. Auto-Revert High-Risk Native Changes

When a new native plugin is detected:

**Identify the Dart surface area:**
1. Find all files in `apps/plot/lib/` that directly import the new package
2. Find all files that import *those* files (walk the transitive import graph)
3. Classify each as NEW (didn't exist at release commit) or MODIFIED (existed but changed)

**Revert:**
1. **NEW files** that exist only because of the native plugin → `git rm`
2. **MODIFIED files** whose changes depend on the plugin → `git checkout {release-commit} -- {path}` to restore the release version
3. **Files that import removed/reverted files** → fix broken imports and remove references to deleted code

**Cascade repair:**
After reverting, grep the codebase for:
- Imports of removed files
- References to removed classes, functions, enums
- Unused imports left behind

Fix each broken reference. This commonly means removing import lines, removing command registrations, and removing callback wiring.

**Stop condition:** If the cascade:
- Touches more than ~10 files, OR
- Involves removing a class used as a mixin on a core widget, OR
- Requires changing function signatures on widely-used APIs

Then STOP and present the situation to the user with the list of affected files and what would need to change.

**Clean up pubspec.yaml:**
- Remove new native dependencies from `dependencies:`
- Remove associated entries from `dependency_overrides:`
- Keep pure Dart additions

### 2d. Apply User-Requested Exclusions

If the user specified exclusions:

- **Commit exclusions** (`exclude commit abc1234`): `git revert --no-commit {hash}` after the merge
- **File/directory exclusions** (`exclude lib/notifications/`): `git checkout {release-commit} -- {paths}`, then fix broken imports

After exclusions, run the same cascade repair as 2c.

### 2e. Pin Version

```bash
# Find the release version
RELEASE_VERSION=$(git show {release-commit}:apps/plot/pubspec.yaml | grep '^version:' | sed 's/version: //')

# Set version in pubspec.yaml (both version: and msix_version: lines)
# Use replace_all since version appears in both places
```

Replace all occurrences of the current version with the release version in `apps/plot/pubspec.yaml`.

### 2f. Verify Asset Compatibility

Shorebird patches only the Dart AOT snapshot. Assets bundled in the original release (`.env`, images, fonts, `NOTICES.Z`) **stay unchanged on device** — the patch cannot update them. The CI workflow uses `--allow-asset-diffs` because `.env` (generated from 1Password in CI) and `NOTICES.Z` (changes with any dependency) always differ. This means any **new** asset referenced by patched Dart code will be missing at runtime.

**Check for new `.env` keys:**

```bash
git diff {release-commit}..HEAD -- apps/plot/lib/env.dart
```

If new env keys were added and the Dart code calls them without a fallback, the patched app will get `null` and may crash. For each new key, either:
- Add a fallback/default in the Dart code so the feature degrades gracefully, OR
- Revert the Dart code that depends on the new key

**Check for new asset files:**

```bash
git diff {release-commit}..HEAD --stat -- apps/plot/assets/
git diff {release-commit}..HEAD -- apps/plot/pubspec.yaml | grep -A5 'assets:'
```

If Dart code loads a new asset path (e.g., `Image.asset('assets/new_icon.png')`), the patched app will throw a `FlutterError` at runtime. Revert or guard the Dart code that references missing assets.

**Check for new font glyphs:**

Font files in packages (e.g., `font_awesome_flutter`) are assets. New icon codepoints render as □ (missing glyph) but don't crash — low risk, flag but proceed.

**Expected (harmless) diffs that always occur:**
- `.env` — CI generates prod env; on-device copy from original release still works unless new keys are required
- `NOTICES.Z` — compressed license text, purely informational
- Font files — only cosmetic if new glyphs are referenced

### 2g. Validate

```bash
cd apps/plot
flutter pub get
flutter analyze
```

Both must succeed. If `flutter analyze` reports errors:
- If they're unused import warnings from the revert process → fix them
- If they're type errors or missing references → the cascade repair missed something, fix it
- If errors persist after two fix attempts → stop and present to user

### 2h. Commit and Push

```bash
git add -A apps/plot/
git commit -m "Merge main into release/{version} for Shorebird patch

<summary of what was merged and any reverts/exclusions>

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"

git push origin release/{version}
```

## Step 3: Trigger Patch Workflows

For each release branch that was successfully pushed:

```bash
gh workflow run patch.yml \
  --ref release/{version} \
  -f ios={true|false} \
  -f android={true|false} \
  -f macos={true|false} \
  -f windows={true|false}
```

Set platform booleans based on which platforms have tags for this version AND were requested by the user.

## Step 4: Summary

Present a final summary:

```
Patch Summary:
  release/1.1.6+325
    Merged: 47 commits from main
    Reverted: (none)
    Platforms: ios, android, macos, windows
    Workflow: https://github.com/plotday/core/actions/runs/XXXXX

  release/1.1.6+322
    Merged: 89 commits from main
    Reverted: flutter_local_notifications (3 files removed, 4 files restored)
    Excluded: lib/notifications/background_handler.dart (user request)
    Platforms: macos
    Workflow: https://github.com/plotday/core/actions/runs/XXXXX
```

## Important Notes

- **Never force-push release branches.** Always merge forward.
- **Always validate with `flutter analyze`** before pushing. A broken patch branch wastes CI time.
- **Podfile.lock changes are informational.** They show what native SDKs changed but Shorebird patches the Dart snapshot, not the native layer. The on-device native binary is fixed.
- **The version in pubspec.yaml must exactly match the release.** Shorebird uses `--release-version` from pubspec to find the correct release artifact to patch against.
- **Return to main when done.** After all branches are processed, `git checkout main` to leave the working tree clean.
