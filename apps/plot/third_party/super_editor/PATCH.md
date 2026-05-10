# super_editor — patched local fork

Source: `super_editor` 0.3.0-dev.51 (pub.dev).

## Why we forked

Flutter 3.41 removed `TextInputStyle` and `TextInputClient.updateStyle(...)`
from `package:flutter/services`. `super_editor` 0.3.0-dev.51 still overrides
the removed method on `DeltaTextInputClientDecorator`, which fails to compile:

```
ime_decoration.dart:53:20: Error: Type 'TextInputStyle' not found.
  void updateStyle(TextInputStyle style) => client?.updateStyle(style);
```

The class also overrides the modern `setStyle({...named})` API (lines 38–50),
which is what Flutter ships now, so the `updateStyle` override is purely
vestigial.

## The patch

`lib/src/default_editor/document_ime/ime_decoration.dart` — removed the
`updateStyle(TextInputStyle)` override on `DeltaTextInputClientDecorator`.

## Cleanup guard

`check-still-needed.sh` runs as the first step of `pnpm lint` (see
`apps/plot/package.json`) and inspects the resolved Flutter SDK's
`text_input.dart`. When the SDK exposes `final class TextInputStyle`, the
script exits non-zero with cleanup instructions, failing CI. That's the
forcing function for removing this fork once Flutter ships
[flutter/flutter#180436](https://github.com/flutter/flutter/pull/180436)
on the stable channel we use.

## When upgrading

When bumping `super_editor`, copy the new version into this directory and
re-apply the patch (delete the `updateStyle(TextInputStyle)` override on
`DeltaTextInputClientDecorator` if upstream still has it). Drop the override
in `apps/plot/pubspec.yaml` and remove this directory entirely once the
guard fires (i.e. the project's Flutter SDK has caught up to PR #180436).
