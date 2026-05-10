import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/util/value.dart';
import 'package:plot/widget/modal.dart';

/// Touch-friendly modal for editing a [Duration] using +/- step buttons and
/// a small set of presets. Returns the chosen [Duration], or `null` to
/// clear it. A dismissed modal returns an absent [Value].
class DurationModal extends Modal {
  DurationModal({this.initial, super.key})
    : super(
        constraints: const BoxConstraints(maxHeight: 360, maxWidth: 360),
        padding: const EdgeInsets.all(16),
        builder: (context) => _DurationModalBody(initial: initial),
      );

  final Duration? initial;

  static const _step = Duration(minutes: 15);
  static const _presets = [
    Duration(minutes: 15),
    Duration(minutes: 30),
    Duration(hours: 1),
    Duration(hours: 2),
  ];

  Future<Value<Duration?>> run(BuildContext context) {
    return super.show<Duration?>(context);
  }
}

class _DurationModalBody extends StatefulWidget {
  const _DurationModalBody({required this.initial});

  final Duration? initial;

  @override
  State<_DurationModalBody> createState() => _DurationModalBodyState();
}

class _DurationModalBodyState extends State<_DurationModalBody> {
  late Duration _value = widget.initial ?? Duration.zero;

  void _bump(Duration delta) {
    setState(() {
      final next = _value + delta;
      _value = next < Duration.zero ? Duration.zero : next;
    });
  }

  void _set(Duration d) => setState(() => _value = d);

  void _commit(Duration? d) {
    Modal.pop<Duration?>(context, Value<Duration?>(d));
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final spacing = theme.spacing;
    return Padding(
      padding: EdgeInsets.all(spacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            _format(_value),
            style: theme.typography.xl3.copyWith(fontWeight: FontWeight.w600),
          ),
          SizedBox(height: spacing.lg),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _StepButton(
                label: '−',
                onTap: () => _bump(-DurationModal._step),
              ),
              SizedBox(width: spacing.lg),
              _StepButton(
                label: '+',
                onTap: () => _bump(DurationModal._step),
              ),
            ],
          ),
          SizedBox(height: spacing.lg),
          Wrap(
            spacing: spacing.sm,
            runSpacing: spacing.sm,
            alignment: WrapAlignment.center,
            children: [
              for (final p in DurationModal._presets)
                FButton(
                  variant: FButtonVariant.outline,
                  onPress: () => _set(p),
                  child: Text(_format(p)),
                ),
            ],
          ),
          SizedBox(height: spacing.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              FButton(
                variant: FButtonVariant.ghost,
                onPress: () => _commit(null),
                child: const Text('Clear'),
              ),
              FButton(
                variant: FButtonVariant.primary,
                onPress: () =>
                    _commit(_value == Duration.zero ? null : _value),
                child: const Text('Done'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _format(Duration d) {
    if (d == Duration.zero) return '0m';
    final h = d.inHours;
    final m = d.inMinutes - h * 60;
    if (h == 0) return '${m}m';
    if (m == 0) return '${h}h';
    return '${h}h ${m}m';
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 60,
        height: 60,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: colors.secondary,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colors.border),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 22, color: colors.foreground),
        ),
      ),
    );
  }
}
