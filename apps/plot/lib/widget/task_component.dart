import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:super_editor/super_editor.dart';

/// Custom [TaskComponentBuilder] for Plot that uses Forui's [FCheckbox]
/// instead of Material's Checkbox.
///
/// This builder creates task components that are compatible with Plot's
/// Forui-based design system, avoiding Material widget dependencies.
class PlotTaskComponentBuilder implements ComponentBuilder {
  PlotTaskComponentBuilder(this._editor);

  final Editor _editor;

  @override
  TaskComponentViewModel? createViewModel(
    Document document,
    DocumentNode node,
  ) {
    if (node is! TaskNode) {
      return null;
    }

    final textDirection = getParagraphDirection(node.text.toPlainText());

    return TaskComponentViewModel(
      nodeId: node.id,
      createdAt: node.metadata[NodeMetadata.createdAt] as DateTime?,
      padding: EdgeInsets.zero,
      indent: node.indent,
      isComplete: node.isComplete,
      setComplete: (bool isComplete) {
        _editor.execute([
          ChangeTaskCompletionRequest(nodeId: node.id, isComplete: isComplete),
        ]);
      },
      text: node.text,
      textDirection: textDirection,
      textAlignment: textDirection == TextDirection.ltr
          ? TextAlign.left
          : TextAlign.right,
      textStyleBuilder: noStyleBuilder,
      selectionColor: const Color(0x00000000),
    );
  }

  @override
  Widget? createComponent(
    SingleColumnDocumentComponentContext componentContext,
    SingleColumnLayoutComponentViewModel componentViewModel,
  ) {
    if (componentViewModel is! TaskComponentViewModel) {
      return null;
    }

    return PlotTaskComponent(
      key: componentContext.componentKey,
      viewModel: componentViewModel,
    );
  }
}

/// Custom task component widget that uses Forui's [FCheckbox].
///
/// This replaces super_editor's [TaskComponent] which uses Material's Checkbox.
class PlotTaskComponent extends StatefulWidget {
  const PlotTaskComponent({
    super.key,
    required this.viewModel,
    this.showDebugPaint = false,
  });

  final TaskComponentViewModel viewModel;
  final bool showDebugPaint;

  @override
  State<PlotTaskComponent> createState() => _PlotTaskComponentState();
}

class _PlotTaskComponentState extends State<PlotTaskComponent>
    with ProxyDocumentComponent<PlotTaskComponent>, ProxyTextComposable {
  final _textKey = GlobalKey();

  @override
  GlobalKey<State<StatefulWidget>> get childDocumentComponentKey => _textKey;

  @override
  TextComposable get childTextComposable =>
      childDocumentComponentKey.currentState as TextComposable;

  /// Computes the [TextStyle] for this task's inner [TextComponent].
  TextStyle _computeStyles(Set<Attribution> attributions) {
    // Show a strikethrough across the entire task if it's complete.
    final style = widget.viewModel.textStyleBuilder(attributions);
    return widget.viewModel.isComplete
        ? style.copyWith(
            decoration: style.decoration == null
                ? TextDecoration.lineThrough
                : TextDecoration.combine([
                    TextDecoration.lineThrough,
                    style.decoration!,
                  ]),
          )
        : style;
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: widget.viewModel.textDirection,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: widget.viewModel.indentCalculator(
              widget.viewModel.textStyleBuilder({}),
              widget.viewModel.indent,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 8, right: 4),
            child: FCheckbox(
              value: widget.viewModel.isComplete,
              onChange: widget.viewModel.setComplete,
              enabled: widget.viewModel.setComplete != null,
            ),
          ),
          Expanded(
            child: TextComponent(
              key: _textKey,
              text: widget.viewModel.text,
              textDirection: widget.viewModel.textDirection,
              textAlign: widget.viewModel.textAlignment,
              textStyleBuilder: _computeStyles,
              inlineWidgetBuilders: widget.viewModel.inlineWidgetBuilders,
              textSelection: widget.viewModel.selection,
              selectionColor: widget.viewModel.selectionColor,
              highlightWhenEmpty: widget.viewModel.highlightWhenEmpty,
              underlines: widget.viewModel.createUnderlines(),
              showDebugPaint: widget.showDebugPaint,
            ),
          ),
        ],
      ),
    );
  }
}
