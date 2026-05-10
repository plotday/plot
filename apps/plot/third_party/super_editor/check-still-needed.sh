#!/usr/bin/env bash
#
# Guard for the third_party/super_editor local fork.
#
# Background: super_editor 0.3.0-dev.51 contains a forward-compat override
# referencing `TextInputStyle` and `TextInputConnection.updateStyle`, which
# at the time of this writing only exist on Flutter master/beta
# (https://github.com/flutter/flutter/pull/180436). The project's pinned
# stable Flutter does not export those symbols, so the upstream package
# fails to compile. We work around it with a patched local fork — see
# third_party/super_editor/PATCH.md.
#
# When the project upgrades to a Flutter SDK that ships PR #180436, the
# upstream super_editor will compile cleanly and the local fork should be
# removed. This script fails `flutter analyze` (via `pnpm lint`) once that
# happens so we don't ship a stale fork.

set -euo pipefail

flutter_root=$(flutter --version --machine 2>/dev/null \
  | sed -n 's/.*"flutterRoot": *"\([^"]*\)".*/\1/p')

if [ -z "${flutter_root:-}" ] || [ ! -d "$flutter_root" ]; then
  echo "super_editor patch guard: could not resolve Flutter root; skipping." >&2
  exit 0
fi

text_input="$flutter_root/packages/flutter/lib/src/services/text_input.dart"

if [ ! -f "$text_input" ]; then
  echo "super_editor patch guard: $text_input not found; skipping." >&2
  exit 0
fi

if grep -q '^final class TextInputStyle' "$text_input"; then
  cat >&2 <<'MSG'

ERROR: Flutter SDK now exposes TextInputStyle.

The upstream super_editor 0.3.0-dev.51 should compile cleanly against this
Flutter, so the local fork at apps/plot/third_party/super_editor/ is no
longer needed.

Cleanup steps:
  1. Remove the `super_editor:` entry from `dependency_overrides:` in
     apps/plot/pubspec.yaml.
  2. Delete apps/plot/third_party/super_editor/.
  3. Drop the `bash third_party/super_editor/check-still-needed.sh &&`
     prefix from the `lint` script in apps/plot/package.json.
  4. Run `flutter pub get` and re-run `pnpm lint`.

MSG
  exit 1
fi
