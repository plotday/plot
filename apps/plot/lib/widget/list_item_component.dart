import 'package:flutter/widgets.dart';
import 'package:super_editor/super_editor.dart';

import 'editor_mention_plugin.dart';

/// [ComponentBuilder] for unordered/ordered list items that prevents the
/// bullet dot or numeral from inheriting inline-color attributions (link,
/// mention) from the first character of the item.
///
/// super_editor's defaults compute the dot/numeral style from
/// `text.getAllAttributionsAt(0)`, so a list item whose first character is
/// part of a link gets a primary-coloured, bold bullet — matching the link,
/// not the surrounding text. This builder filters those attributions out so
/// the marker always renders in the base text style.
class PlotListItemComponentBuilder implements ComponentBuilder {
  const PlotListItemComponentBuilder();

  static const _delegate = ListItemComponentBuilder();

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
    if (componentViewModel is UnorderedListItemComponentViewModel) {
      return UnorderedListItemComponent(
        componentKey: componentContext.componentKey,
        text: componentViewModel.text,
        styleBuilder: componentViewModel.textStyleBuilder,
        inlineWidgetBuilders: componentViewModel.inlineWidgetBuilders,
        dotBuilder: _plotUnorderedDotBuilder,
        dotStyle: componentViewModel.dotStyle,
        indent: componentViewModel.indent,
        textSelection: componentViewModel.selection,
        textDirection: componentViewModel.textDirection,
        textAlignment: componentViewModel.textAlignment,
        selectionColor: componentViewModel.selectionColor,
        highlightWhenEmpty: componentViewModel.highlightWhenEmpty,
        underlines: componentViewModel.createUnderlines(),
      );
    }
    if (componentViewModel is OrderedListItemComponentViewModel) {
      return OrderedListItemComponent(
        componentKey: componentContext.componentKey,
        indent: componentViewModel.indent,
        listIndex: componentViewModel.ordinalValue!,
        text: componentViewModel.text,
        textDirection: componentViewModel.textDirection,
        textAlignment: componentViewModel.textAlignment,
        styleBuilder: componentViewModel.textStyleBuilder,
        inlineWidgetBuilders: componentViewModel.inlineWidgetBuilders,
        numeralBuilder: _plotOrderedNumeralBuilder,
        numeralStyle: componentViewModel.numeralStyle,
        textSelection: componentViewModel.selection,
        selectionColor: componentViewModel.selectionColor,
        highlightWhenEmpty: componentViewModel.highlightWhenEmpty,
        underlines: componentViewModel.createUnderlines(),
      );
    }
    return null;
  }
}

bool _isInlineColorAttribution(Attribution attr) {
  return attr is LinkAttribution ||
      attr is CommittedEditorMentionAttribution ||
      attr == editorMentionComposingAttribution;
}

Set<Attribution> _baseAttributionsAt0(AttributedText text) {
  final attributions = text.getAllAttributionsAt(0).toSet();
  attributions.removeWhere(_isInlineColorAttribution);
  return attributions;
}

Widget _plotUnorderedDotBuilder(
  BuildContext context,
  UnorderedListItemComponent component,
) {
  final textStyle = component.styleBuilder(_baseAttributionsAt0(component.text));
  final dotSize = component.dotStyle?.size ?? const Size(4, 4);

  return Align(
    alignment: Alignment.centerRight,
    child: Text.rich(
      TextSpan(
        // Zero-width joiner aligns the bullet vertically with the text.
        text: '‌',
        style: textStyle,
        children: [
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Container(
              width: dotSize.width,
              height: dotSize.height,
              margin: const EdgeInsets.only(right: 10),
              decoration: BoxDecoration(
                shape: component.dotStyle?.shape ?? BoxShape.circle,
                color: component.dotStyle?.color ?? textStyle.color,
              ),
            ),
          ),
        ],
      ),
      textScaler: const TextScaler.linear(1.0),
    ),
  );
}

Widget _plotOrderedNumeralBuilder(
  BuildContext context,
  OrderedListItemComponent component,
) {
  final textStyle = component.styleBuilder(_baseAttributionsAt0(component.text));

  return OverflowBox(
    maxWidth: double.infinity,
    maxHeight: double.infinity,
    child: Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(right: 5.0),
        child: Text(
          '${_numeralForIndex(component.listIndex, component.numeralStyle)}.',
          textAlign: TextAlign.right,
          style: textStyle,
        ),
      ),
    ),
  );
}

String _numeralForIndex(int numeral, OrderedListNumeralStyle numeralStyle) {
  return switch (numeralStyle) {
    OrderedListNumeralStyle.arabic => '$numeral',
    OrderedListNumeralStyle.lowerAlpha => _toAlpha(numeral, lower: true),
    OrderedListNumeralStyle.upperAlpha => _toAlpha(numeral, lower: false),
    OrderedListNumeralStyle.lowerRoman => _toRoman(numeral, lower: true),
    OrderedListNumeralStyle.upperRoman => _toRoman(numeral, lower: false),
  };
}

String _toAlpha(int n, {required bool lower}) {
  if (n <= 0) return '$n';
  final buf = StringBuffer();
  var v = n;
  while (v > 0) {
    final r = (v - 1) % 26;
    buf.write(String.fromCharCode((lower ? 0x61 : 0x41) + r));
    v = (v - 1) ~/ 26;
  }
  return buf.toString().split('').reversed.join();
}

String _toRoman(int n, {required bool lower}) {
  if (n <= 0) return '$n';
  const values = [
    1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1,
  ];
  const symbols = [
    'M', 'CM', 'D', 'CD', 'C', 'XC', 'L', 'XL', 'X', 'IX', 'V', 'IV', 'I',
  ];
  final buf = StringBuffer();
  var v = n;
  for (var i = 0; i < values.length; i++) {
    while (v >= values[i]) {
      buf.write(symbols[i]);
      v -= values[i];
    }
  }
  return lower ? buf.toString().toLowerCase() : buf.toString();
}
