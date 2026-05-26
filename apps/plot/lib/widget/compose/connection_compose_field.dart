import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/widget/widget.dart';

/// Compose-surface connection field. Renders as a ghost text field with
/// a popover dropdown of MRU-ranked candidates. Touch taps open the
/// existing ConnectionPickerModal.
class ConnectionComposeField extends StatefulWidget {
  const ConnectionComposeField({
    super.key,
    required this.activeChoice,
    required this.candidates,
    required this.onPicked,
    required this.openTouchModal,
  });

  /// Currently selected choice (always non-null — defaults to Plot thread).
  final ConnectionChoice activeChoice;

  /// All candidates for the dropdown, already MRU-ranked for the priority.
  final List<ConnectionChoice> candidates;

  /// Persist the picked choice on the draft.
  final Future<void> Function(ConnectionChoice choice) onPicked;

  /// On touch, opens the existing ConnectionPickerModal. NewThreadPage owns
  /// the modal helper.
  final Future<void> Function() openTouchModal;

  @override
  State<ConnectionComposeField> createState() =>
      _ConnectionComposeFieldState();
}

class _ConnectionComposeFieldState extends State<ConnectionComposeField> {
  final DropdownController _dropdown = DropdownController();
  final FocusNode _focusNode = FocusNode();
  final TextEditingController _controller = TextEditingController();
  final GlobalKey<ComposeDropdownState<ConnectionChoice>> _dropdownKey =
      GlobalKey<ComposeDropdownState<ConnectionChoice>>();

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChange);
    _controller.addListener(_onTextChange);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    _controller.removeListener(_onTextChange);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    if (_focusNode.hasFocus && hasPhysicalKeyboard()) {
      _dropdown.show();
    } else {
      _dropdown.hide();
      if (_controller.text.isNotEmpty) _controller.clear();
    }
  }

  void _onTextChange() {
    // Trigger a rebuild so the filtered candidates re-render.
    setState(() {});
  }

  Iterable<ConnectionChoice> get _filteredCandidates {
    final query = _controller.text.trim().toLowerCase();
    if (query.isEmpty) return widget.candidates;
    return widget.candidates.where(
      (c) => c.searchText.toLowerCase().contains(query),
    );
  }

  Future<void> _handleTap() async {
    if (hasPhysicalKeyboard()) {
      _focusNode.requestFocus();
    } else {
      await widget.openTouchModal();
    }
  }

  Future<void> _handlePicked(ConnectionChoice choice) async {
    _controller.clear();
    _focusNode.unfocus();
    _dropdown.hide();
    await widget.onPicked(choice);
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    final state = _dropdownKey.currentState;
    if (state == null) return KeyEventResult.ignored;
    return state.handleKey(event)
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _handleKey,
      child: ComposeFieldRow(
        icon: PlotIcon.link,
        tooltip: 'Connection',
        onTapField: _handleTap,
        child: ComposeDropdown<ConnectionChoice>(
          key: _dropdownKey,
          controller: _dropdown,
          autoFocusOnShow: false,
          items: _filteredCandidates.toList(growable: false),
          itemBuilder: (context, choice, highlighted) {
            return Container(
              color: highlighted ? theme.plotColors.highlight : null,
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
              child: switch (choice) {
                PlotThreadChoice() => Row(
                    children: [
                      Icon(PlotIcon.note, size: theme.iconSizes.sm),
                      const SizedBox(width: 8),
                      const Text('Plot thread'),
                    ],
                  ),
                TargetConnectionChoice(:final target) =>
                  createTargetTile(context, target),
              },
            );
          },
          onSelected: _handlePicked,
          child: ComposeValueInput(
            controller: _controller,
            focusNode: _focusNode,
            hint: 'Plot thread',
            value: Text(widget.activeChoice.label),
            readOnly: isTouchPlatform(),
          ),
        ),
      ),
    );
  }
}
