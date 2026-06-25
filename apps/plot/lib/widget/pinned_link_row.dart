import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:plot/state/layout.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/theme.dart' show darkenTheme;
import 'package:plot/widget/edit_link_modal.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/logo_image.dart';

/// Filters a thread's canonical links to the user-pinned bookmarks that render
/// as [PinnedLinkRow]s: links with no connector type config and a source URL.
/// Connector-managed links (a non-null [Link.getTypeConfig]) are excluded —
/// they keep the header treatment (PrimaryLinkHeaderActions).
Iterable<Link> pinnedBookmarkLinks(Iterable<Link> links) =>
    links.where((l) => l.getTypeConfig() == null && l.sourceUrl != null);

/// A compact row for a user-pinned bookmark [Link], rendered above the notes
/// list at the top of a thread. Shows the source logo + title; tapping opens
/// the URL externally. A trailing "…" menu offers Edit link and Unpin from
/// thread.
class PinnedLinkRow extends StatefulWidget {
  const PinnedLinkRow({required this.link, super.key});

  final Link link;

  @override
  State<PinnedLinkRow> createState() => _PinnedLinkRowState();
}

class _PinnedLinkRowState extends State<PinnedLinkRow> {
  bool _hovered = false;

  Future<void> _open() async {
    final url = widget.link.sourceUrl;
    if (url == null) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final link = widget.link;
    final hasUrl = link.sourceUrl != null;
    return FTheme(
      data: darkenTheme(context, context.theme, context.colour, steps: 2),
      child: Builder(
        builder: (context) {
          final linkLogo = link.logoForBrightness(context.colour.brightness);
          return GestureDetector(
            onTap: hasUrl ? _open : null,
            child: MouseRegion(
              cursor: hasUrl
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              onEnter: (_) => setState(() => _hovered = true),
              onExit: (_) => setState(() => _hovered = false),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: _hovered
                      ? context.theme.colors.secondary
                      : context.theme.colors.background,
                  border: Border(
                    bottom: BorderSide(
                      color: context.theme.colors.border,
                      width: 0.5,
                    ),
                  ),
                ),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: context.isMultiPanel
                        ? 20.0
                        : context.contentPaddingH,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      if (linkLogo != null)
                        LogoImage(
                          url: linkLogo,
                          size: 14,
                          fallback: const Icon(PlotIcon.link, size: 14),
                        )
                      else
                        const Icon(PlotIcon.link, size: 14),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          link.title ?? '',
                          style: context.theme.typography.sm.copyWith(
                            color: context.theme.colors.foreground,
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                      const SizedBox(width: 8),
                      _PinnedLinkMenu(link: link),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// "…" overlay menu for a pinned bookmark row: Edit link + Unpin from thread.
/// Mirrors the structure of `_NoteLinkMenu` in note_action.dart.
class _PinnedLinkMenu extends StatefulWidget {
  const _PinnedLinkMenu({required this.link});

  final Link link;

  @override
  State<_PinnedLinkMenu> createState() => _PinnedLinkMenuState();
}

class _PinnedLinkMenuState extends State<_PinnedLinkMenu> {
  final _controller = OverlayPortalController();

  @override
  Widget build(BuildContext context) {
    final style = context.theme.popoverMenuStyle;

    return OverlayPortal(
      controller: _controller,
      overlayChildBuilder: (overlayContext) {
        final buttonBox = this.context.findRenderObject() as RenderBox;
        final overlay =
            Overlay.of(overlayContext).context.findRenderObject() as RenderBox;
        final position = buttonBox.localToGlobal(
          Offset(buttonBox.size.width, buttonBox.size.height),
          ancestor: overlay,
        );

        return Positioned(
          top: position.dy,
          right: overlay.size.width - position.dx,
          child: TapRegion(
            onTapOutside: (_) => _controller.hide(),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: style.maxWidth),
              child: DecoratedBox(
                decoration: style.decoration,
                child: FInheritedItemData(
                  child: FItemGroup.merge(
                    style: style.itemGroupStyle,
                    divider: FItemDivider.full,
                    children: [FItemGroup(children: _buildMenuItems())],
                  ),
                ),
              ),
            ),
          ),
        );
      },
      child: GestureDetector(
        onTap: () {
          if (_controller.isShowing) {
            _controller.hide();
          } else {
            _controller.show();
          }
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.basic,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Icon(
              PlotIcon.more,
              size: 14,
              color: context.theme.colors.foreground.withValues(alpha: 0.5),
            ),
          ),
        ),
      ),
    );
  }

  List<FItem> _buildMenuItems() {
    return [
      FItem(
        title: const Text('Edit link'),
        onPress: () {
          _controller.hide();
          _editLink();
        },
      ),
      FItem(
        title: const Text('Unpin from thread'),
        onPress: () {
          _controller.hide();
          Link.unpinFromThread(widget.link);
        },
      ),
    ];
  }

  Future<void> _editLink() async {
    final result = await EditLinkModal(
      initialTitle: widget.link.title ?? '',
      initialUrl: widget.link.sourceUrl ?? '',
    ).run(context);
    if (result == null) return;
    if (result.title == widget.link.title &&
        result.url == widget.link.sourceUrl) {
      return;
    }
    await Link.updateTitleAndUrl(
      widget.link,
      title: result.title.isEmpty ? null : result.title,
      url: result.url,
    );
  }
}
