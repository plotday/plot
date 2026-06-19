import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

/// A forui field `builder` (for [FTextField], [FDateField], [FTimeField]) that
/// overrides the field's text-selection highlight so it matches the note
/// editor's.
///
/// forui has no per-field selection-colour knob: it derives the highlight from
/// the cursor colour (`cursorColor` at 40% alpha — a muted grey that reads too
/// dark over light fields and too light over dark ones, hurting contrast with
/// the selected text) and bakes it into a [Theme] wrapped *around* the field. A
/// Material [Theme] in turn bridges that into the innermost [DefaultSelectionStyle],
/// which shadows any app-level override.
///
/// The one override point inside forui's [Theme] is the field's own `builder`:
/// forui nests its output within that [Theme], so a [DefaultSelectionStyle] here
/// sits closer to the editor than forui's bridged one and wins.
///
/// The selection colour is [FColors.primaryForeground] — the exact value the
/// note editor uses for its selection (see [Editor]'s `SelectionStyles`). It is
/// a pale accent tint in light mode and a dark accent tint in dark mode, both of
/// which keep the selected text legible. The cursor keeps forui's muted tone
/// ([FColors.mutedForeground]).
///
/// Generic over the field's style type so it satisfies `FFieldBuilder<...>` for
/// every field that exposes a `builder` (the style argument is unused). Pass it
/// directly — Dart infers the type argument from the field:
/// ```dart
/// FTextField(builder: fieldSelectionBuilder, ...)
/// ```
Widget fieldSelectionBuilder<S>(
  BuildContext context,
  S style,
  Set<FTextFieldVariant> variants,
  Widget field,
) {
  final colors = context.theme.colors;
  return DefaultSelectionStyle(
    selectionColor: colors.primaryForeground,
    cursorColor: colors.mutedForeground,
    child: field,
  );
}
