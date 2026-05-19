import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:plot/style/spacing.dart';
import 'package:super_editor/super_editor.dart';

/// Component builder for blockquotes that renders the typical left-border
/// style instead of super_editor's default tinted background. Reuses the
/// default [BlockquoteComponentBuilder] for view-model creation so paste,
/// selection, and serialization keep working.
class PlotBlockquoteComponentBuilder implements ComponentBuilder {
  const PlotBlockquoteComponentBuilder();

  static const _delegate = BlockquoteComponentBuilder();

  @override
  SingleColumnLayoutComponentViewModel? createViewModel(
    Document document,
    DocumentNode node,
  ) {
    return _delegate.createViewModel(document, node);
  }

  @override
  Widget? createComponent(
    SingleColumnDocumentComponentContext componentContext,
    SingleColumnLayoutComponentViewModel componentViewModel,
  ) {
    if (componentViewModel is! BlockquoteComponentViewModel) return null;

    return _PlotBlockquoteComponent(
      textKey: componentContext.componentKey,
      viewModel: componentViewModel,
    );
  }
}

class _PlotBlockquoteComponent extends StatelessWidget {
  const _PlotBlockquoteComponent({
    required this.textKey,
    required this.viewModel,
  });

  final GlobalKey textKey;
  final BlockquoteComponentViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final spacing = context.theme.spacing;
    // Vertical spacing lives inside the bordered container on TOP only so
    // that consecutive blockquote paragraphs render with a continuous left
    // border AND the inter-paragraph gap matches the `spacing.md` rhythm
    // used elsewhere. The stylesheet zeroes the outer top padding for
    // `blockquote` blocks; the inner top padding here provides the gap
    // above each quoted paragraph (including the first one).
    return IgnorePointer(
      child: Container(
        padding: EdgeInsets.fromLTRB(12, spacing.md, 0, 0),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(width: 3, color: colors.border),
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: viewModel.indentCalculator(
                viewModel.textStyleBuilder({}),
                viewModel.indent,
              ),
            ),
            Expanded(
              child: TextComponent(
                key: textKey,
                text: viewModel.text,
                textStyleBuilder: viewModel.textStyleBuilder,
                inlineWidgetBuilders: viewModel.inlineWidgetBuilders,
                textSelection: viewModel.selection,
                selectionColor: viewModel.selectionColor,
                highlightWhenEmpty: viewModel.highlightWhenEmpty,
                underlines: viewModel.createUnderlines(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
