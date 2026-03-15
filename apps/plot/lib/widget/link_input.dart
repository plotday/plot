import 'dart:async';

import 'package:flutter/material.dart' show OutlineInputBorder;
import 'package:flutter/services.dart';

import 'package:plot/store/store.dart';
import 'package:plot/util/url_title.dart' show fetchUrlMetadata;
import 'package:plot/widget/widget.dart' hide Link;

/// A search/URL input for creating or finding links.
/// Replaces the ThreadEditor when the "Link" type is selected in NewThreadPage.
class LinkInput extends StatefulWidget {
  const LinkInput({
    required this.priority,
    required this.onNavigateToThread,
    required this.onCreateLink,
    this.initialUrl,
    this.flushToBottom = false,
    super.key,
  });

  final Priority priority;
  final void Function(Thread thread) onNavigateToThread;
  final void Function(String url, String? title, String? favicon) onCreateLink;
  final String? initialUrl;
  final bool flushToBottom;

  @override
  State<LinkInput> createState() => _LinkInputState();
}

class _LinkInputState extends State<LinkInput> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  Timer? _debounceTimer;

  List<_LinkResult> _results = [];
  bool _inputIsUrl = false;
  String? _fetchedTitle;
  String? _fetchedFavicon;
  bool _isLoading = false;
  int _highlightedIndex = 0;
  String _lastSearchText = '';

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);

    // Pre-fill with shared URL if provided
    if (widget.initialUrl != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _controller.text = widget.initialUrl!;
        }
      });
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Total number of selectable items (results + optional "create" row).
  int get _itemCount {
    if (_isLoading || _controller.text.trim().isEmpty) return 0;
    final extra = (_inputIsUrl && _results.isEmpty) ? 1 : 0;
    return _results.length.clamp(0, 20) + extra;
  }

  void _onTextChanged() {
    final text = _controller.text.trim();
    if (text == _lastSearchText) return;
    _lastSearchText = text;

    _debounceTimer?.cancel();

    if (text.isEmpty) {
      setState(() {
        _results = [];
        _inputIsUrl = false;
        _fetchedTitle = null;
        _fetchedFavicon = null;
        _isLoading = false;
        _highlightedIndex = 0;
      });
      return;
    }

    setState(() => _isLoading = true);

    _debounceTimer = Timer(const Duration(milliseconds: 250), () {
      _search(text);
    });
  }

  static bool _checkIsUrl(String text) {
    final uri = Uri.tryParse(text);
    return uri != null &&
        uri.hasScheme &&
        (uri.scheme == 'http' || uri.scheme == 'https');
  }

  Future<void> _search(String text) async {
    final isUrl = _checkIsUrl(text);

    List<_LinkResult> results;
    String? title;
    String? favicon;

    if (isUrl) {
      final links = await Link.findBySourceUrl(text);
      results = await _loadThreadsForLinks(links);

      if (results.isEmpty) {
        final metadata = await fetchUrlMetadata(text);
        title = metadata.title;
        favicon = metadata.favicon;
      }
    } else {
      final links = await Link.searchByTitle(text);
      results = await _loadThreadsForLinks(links);
    }

    if (!mounted) return;
    if (_controller.text.trim() != text) return;

    setState(() {
      _results = results;
      _inputIsUrl = isUrl;
      _fetchedTitle = title;
      _fetchedFavicon = favicon;
      _isLoading = false;
      _highlightedIndex = 0;
    });
  }

  Future<List<_LinkResult>> _loadThreadsForLinks(List<Link> links) async {
    final results = <_LinkResult>[];
    for (final link in links) {
      if (link.threadId == null) {
        // Threadless link — include with null thread
        results.add(_LinkResult(link: link, thread: null));
        continue;
      }
      try {
        final thread = await Thread.getOne(link.threadId!);
        results.add(_LinkResult(link: link, thread: thread));
      } catch (_) {
        // Thread not found — skip
      }
    }
    return results;
  }

  void _moveHighlight(int offset) {
    final count = _itemCount;
    if (count == 0) return;
    setState(() {
      _highlightedIndex = (_highlightedIndex + offset).clamp(0, count - 1);
    });
  }

  void _activateHighlighted() {
    final count = _itemCount;
    if (count == 0 || _highlightedIndex < 0 || _highlightedIndex >= count) {
      return;
    }

    if (_highlightedIndex < _results.length) {
      final result = _results[_highlightedIndex];
      if (result.thread != null) {
        widget.onNavigateToThread(result.thread!);
      } else if (result.link.sourceUrl != null) {
        // Threadless link — treat as a create with existing link data
        widget.onCreateLink(result.link.sourceUrl!, result.link.title, result.link.logo ?? _fetchedFavicon);
      }
    } else {
      // "Create new link" row
      widget.onCreateLink(_controller.text.trim(), _fetchedTitle, _fetchedFavicon);
    }
  }

  @override
  Widget build(BuildContext context) {
    return EditableArea(
      position: widget.flushToBottom
          ? EditableAreaPosition.bottom
          : EditableAreaPosition.middle,
      padding: false,
      autofocus: true,
      flushToBottom: widget.flushToBottom,
      builder: (context, areaFocusNode) {
        return Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.arrowUp):
                MoveListSelectionIntent(-1),
            SingleActivator(LogicalKeyboardKey.arrowDown):
                MoveListSelectionIntent(1),
            SingleActivator(LogicalKeyboardKey.enter):
                ActivateListSelectionIntent(),
            SingleActivator(LogicalKeyboardKey.escape): ClearSearchIntent(),
          },
          child: Actions(
            actions: {
              MoveListSelectionIntent: CallbackAction<MoveListSelectionIntent>(
                onInvoke: (intent) {
                  _moveHighlight(intent.offset);
                  return KeyEventResult.handled;
                },
              ),
              ActivateListSelectionIntent:
                  CallbackAction<ActivateListSelectionIntent>(
                    onInvoke: (intent) {
                      _activateHighlighted();
                      return KeyEventResult.handled;
                    },
                  ),
              ClearSearchIntent: CallbackAction<ClearSearchIntent>(
                onInvoke: (intent) {
                  _controller.clear();
                  return KeyEventResult.handled;
                },
              ),
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: FTextField(
                    focusNode: _focusNode,
                    control: .managed(controller: _controller),
                    hint: 'Search or paste a link',
                    autofocus: true,
                    autocorrect: false,
                    keyboardType: TextInputType.url,
                    style: FTextFieldStyleDelta.delta(
                      contentPadding: EdgeInsetsGeometryDelta.value(
                        EdgeInsets.zero,
                      ),
                      contentTextStyle: FVariantsDelta.delta([
                        FVariantOperation.all(TextStyleDelta.delta(
                          fontSize: context.theme.typography.md.fontSize,
                          height: 1.4,
                        )),
                      ]),
                      hintTextStyle: FVariantsDelta.delta([
                        FVariantOperation.all(TextStyleDelta.value(
                          context.theme.typography.md.copyWith(
                            height: 1.4,
                            color: context.theme.colors.mutedForeground,
                          ),
                        )),
                      ]),
                      border: FVariantsValueDelta.delta([
                        FVariantValueDeltaOperation.all(
                          const OutlineInputBorder(
                            borderSide: BorderSide(
                              width: 0,
                              style: BorderStyle.none,
                            ),
                          ),
                        ),
                      ]),
                    ),
                    onSubmit: (_) => _activateHighlighted(),
                  ),
                ),

                if (_isLoading)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Spinner(size: 14),
                        const SizedBox(width: 8),
                        Text(
                          'Searching...',
                          style: context.theme.typography.sm.copyWith(
                            color: context.theme.colors.mutedForeground,
                          ),
                        ),
                      ],
                    ),
                  ),

                if (!_isLoading && _controller.text.trim().isNotEmpty) ...[
                  // Existing link results (scrollable, capped at 20)
                  if (_results.isNotEmpty)
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        itemCount: _results.length.clamp(0, 20),
                        itemBuilder: (context, i) =>
                            _buildResultTile(context, i, _results[i]),
                      ),
                    ),

                  // "Create new link" option for unmatched URLs
                  if (_inputIsUrl && _results.isEmpty)
                    _buildCreateTile(context, _results.length),

                  // "No results" for search terms with no matches
                  if (!_inputIsUrl && _results.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Text(
                        'No links found',
                        style: context.theme.typography.sm.copyWith(
                          color: context.theme.colors.mutedForeground,
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildLinkLogo(BuildContext context, Link link) {
    final logoUrl = link.logoForBrightness(
      MediaQuery.platformBrightnessOf(context),
    );
    if (logoUrl != null) {
      return LogoImage(
        url: logoUrl,
        size: 16,
        fallback: const Icon(PlotIcon.link, size: 16),
      );
    }
    return const Icon(PlotIcon.link, size: 16);
  }

  Widget _buildResultTile(BuildContext context, int index, _LinkResult result) {
    return MouseRegion(
      onEnter: (_) => setState(() => _highlightedIndex = index),
      child: GestureDetector(
        onTap: () {
          if (result.thread != null) {
            widget.onNavigateToThread(result.thread!);
          } else if (result.link.sourceUrl != null) {
            widget.onCreateLink(result.link.sourceUrl!, result.link.title, result.link.logo);
          }
        },
        child: Container(
          decoration: BoxDecoration(
            color: index == _highlightedIndex
                ? context.theme.colors.secondary
                : null,
          ),
          child: ListTile(
            leadingBuilder: (_, _) => Padding(
              padding: const EdgeInsets.only(left: 20, right: 8),
              child: _buildLinkLogo(context, result.link),
            ),
            title: result.link.title ?? result.link.sourceUrl ?? 'Link',
            noHoverHighlight: true,
            noBackground: true,
          ),
        ),
      ),
    );
  }

  Widget _buildCreateTile(BuildContext context, int index) {
    final url = _controller.text.trim();
    return MouseRegion(
      onEnter: (_) => setState(() => _highlightedIndex = index),
      child: GestureDetector(
        onTap: () => widget.onCreateLink(url, _fetchedTitle, _fetchedFavicon),
        child: Container(
          decoration: BoxDecoration(
            color: index == _highlightedIndex
                ? context.theme.colors.secondary
                : null,
          ),
          child: ListTile(
            leadingBuilder: _fetchedFavicon != null
                ? (_, _) => Padding(
                    padding: const EdgeInsets.only(left: 20, right: 8),
                    child: LogoImage(
                      url: _fetchedFavicon!,
                      size: 16,
                      fallback: const Icon(PlotIcon.add, size: 16),
                    ),
                  )
                : null,
            icon: _fetchedFavicon == null ? PlotIcon.add : null,
            title: _fetchedTitle ?? url,
            subtitle: _fetchedTitle != null ? url : null,
            noHoverHighlight: true,
            noBackground: true,
          ),
        ),
      ),
    );
  }
}

class ClearSearchIntent extends Intent {
  const ClearSearchIntent();
}

class _LinkResult {
  final Link link;
  final Thread? thread;

  _LinkResult({required this.link, this.thread});
}
