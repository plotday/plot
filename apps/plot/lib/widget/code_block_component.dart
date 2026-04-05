import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:forui/forui.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/spacing.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/csharp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/shell.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/github-dark.dart';
import 'package:re_highlight/styles/github.dart';
import 'package:super_editor/super_editor.dart';

/// Singleton highlighter instance with common languages registered.
final Highlight _highlighter = Highlight()
  ..registerLanguages({
    'bash': langBash,
    'c': langC,
    'cpp': langCpp,
    'csharp': langCsharp,
    'css': langCss,
    'dart': langDart,
    'go': langGo,
    'java': langJava,
    'javascript': langJavascript,
    'json': langJson,
    'kotlin': langKotlin,
    'markdown': langMarkdown,
    'php': langPhp,
    'python': langPython,
    'ruby': langRuby,
    'rust': langRust,
    'shell': langShell,
    'sh': langBash,
    'sql': langSql,
    'swift': langSwift,
    'ts': langTypescript,
    'typescript': langTypescript,
    'js': langJavascript,
    'xml': langXml,
    'html': langXml,
    'yaml': langYaml,
    'yml': langYaml,
  });

final _logLinePattern = RegExp(r'^\[(INFO|WARN|ERROR|DEBUG|TRACE)\] ');

/// Returns true when the code block looks like structured log output,
/// so we can skip auto-detection which highlights random English words.
bool _looksLikeLogs(String code) {
  final lines = code.split('\n').where((l) => l.isNotEmpty);
  return lines.isNotEmpty && lines.every((l) => _logLinePattern.hasMatch(l));
}

/// Component builder for code blocks with syntax highlighting and copy button.
class PlotCodeBlockComponentBuilder implements ComponentBuilder {
  const PlotCodeBlockComponentBuilder();

  @override
  SingleColumnLayoutComponentViewModel? createViewModel(
    Document document,
    DocumentNode node,
  ) {
    if (node is! ParagraphNode) return null;
    if (node.metadata['blockType'] != codeAttribution) return null;

    return CodeBlockViewModel(
      nodeId: node.id,
      createdAt: node.metadata[NodeMetadata.createdAt] as DateTime?,
      padding: EdgeInsets.zero,
      text: node.text,
      language: node.metadata['language'] as String?,
    );
  }

  @override
  Widget? createComponent(
    SingleColumnDocumentComponentContext componentContext,
    SingleColumnLayoutComponentViewModel componentViewModel,
  ) {
    if (componentViewModel is! CodeBlockViewModel) return null;

    return PlotCodeBlockComponent(
      key: componentContext.componentKey,
      viewModel: componentViewModel,
    );
  }
}

class CodeBlockViewModel extends SingleColumnLayoutComponentViewModel {
  CodeBlockViewModel({
    required super.nodeId,
    required super.createdAt,
    required super.padding,
    required this.text,
    this.language,
  });

  final AttributedText text;
  final String? language;

  @override
  SingleColumnLayoutComponentViewModel copy() {
    return CodeBlockViewModel(
      nodeId: nodeId,
      createdAt: createdAt,
      padding: padding,
      text: text,
      language: language,
    );
  }
}

class PlotCodeBlockComponent extends StatefulWidget {
  const PlotCodeBlockComponent({
    super.key,
    required this.viewModel,
  });

  final CodeBlockViewModel viewModel;

  @override
  State<PlotCodeBlockComponent> createState() => _PlotCodeBlockComponentState();
}

class _PlotCodeBlockComponentState extends State<PlotCodeBlockComponent>
    with ProxyDocumentComponent<PlotCodeBlockComponent> {
  final _boxKey = GlobalKey();
  bool _copied = false;
  Timer? _copiedTimer;

  @override
  GlobalKey<State<StatefulWidget>> get childDocumentComponentKey => _boxKey;

  @override
  void dispose() {
    _copiedTimer?.cancel();
    super.dispose();
  }

  void _copyToClipboard() {
    final text = widget.viewModel.text.toPlainText();
    Clipboard.setData(ClipboardData(text: text));
    setState(() => _copied = true);
    _copiedTimer?.cancel();
    _copiedTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  TextSpan _buildHighlightedSpan(
    String code,
    String? language,
    TextStyle baseStyle,
    bool isDark,
  ) {
    final theme = isDark ? githubDarkTheme : githubTheme;

    try {
      final HighlightResult result;
      if (language != null && _highlighter.getLanguage(language) != null) {
        result = _highlighter.highlight(code: code, language: language);
      } else if (_looksLikeLogs(code)) {
        return TextSpan(text: code, style: baseStyle);
      } else {
        result = _highlighter.highlightAuto(code);
      }
      final renderer = TextSpanRenderer(baseStyle, theme);
      result.render(renderer);
      return renderer.span ?? TextSpan(text: code, style: baseStyle);
    } catch (_) {
      return TextSpan(text: code, style: baseStyle);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.colour.brightness == Brightness.dark;
    final spacing = context.theme.spacing;
    final colors = context.theme.colors;

    final baseStyle = context.theme.typography.md.copyWith(
      fontFamily:
          'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace',
      fontSize: context.theme.typography.md.fontSize != null
          ? context.theme.typography.md.fontSize! * 0.85
          : null,
      height: 1.5,
      color: isDark ? colors.foreground : null,
    );

    final code = widget.viewModel.text.toPlainText();
    final highlightedSpan =
        _buildHighlightedSpan(code, widget.viewModel.language, baseStyle, isDark);

    final bgColor = context.colour.highlight;

    return BoxComponent(
      key: _boxKey,
      isVisuallySelectable: false,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Stack(
          children: [
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: spacing.lg,
                vertical: spacing.md,
              ),
              child: RichText(text: highlightedSpan),
            ),
            Positioned(
              top: spacing.xs,
              right: spacing.xs,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.viewModel.language != null)
                    Padding(
                      padding: EdgeInsets.only(right: spacing.xs),
                      child: Text(
                        widget.viewModel.language!,
                        style: context.theme.typography.xs.copyWith(
                          color: colors.mutedForeground,
                        ),
                      ),
                    ),
                  GestureDetector(
                    onTap: _copyToClipboard,
                    child: Padding(
                      padding: EdgeInsets.all(spacing.sm),
                      child: Icon(
                        _copied
                            ? FontAwesomeIcons.check
                            : FontAwesomeIcons.clipboard,
                        size: 12,
                        color: _copied
                            ? colors.primary
                            : colors.mutedForeground,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
