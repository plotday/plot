import 'package:flutter/widgets.dart';

/// Bridges a compound input widget's existing increment/decrement actions to a
/// parent that drives them by other means (e.g. cursor keys at the form-row
/// level). Mirrors the `FormChannelListController` hook pattern: the child
/// widget populates the callbacks during build; the parent invokes them.
///
/// All callbacks are null until the child assigns them.
class StepController {
  /// Small decrement (e.g. -15 minutes / -1 day). Bound to `←`.
  VoidCallback? stepBack;

  /// Small increment (e.g. +15 minutes / +1 day). Bound to `→`.
  VoidCallback? stepForward;

  /// Large decrement (e.g. -1 hour / -1 week). Bound to `Shift+←`.
  VoidCallback? jumpBack;

  /// Large increment (e.g. +1 hour / +1 week). Bound to `Shift+→`.
  VoidCallback? jumpForward;

  /// Move keyboard focus into the child's inner editable field so the user can
  /// type a value. Invoked when the form row is activated (Enter / tap).
  VoidCallback? focusEditor;
}
