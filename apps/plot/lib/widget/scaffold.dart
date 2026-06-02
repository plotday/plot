import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:forui/forui.dart';
import 'package:platform_builder/platform_builder.dart';
import 'package:window_manager/window_manager.dart';

import 'modal.dart';
import 'panel_content_clip.dart';
import 'window.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/style/theme.dart';
import 'package:plot/style/colors.dart';

class Scaffold extends StatelessWidget {
  const Scaffold({
    required this.body,
    this.header,
    this.sidebar,
    this.translucent = false,
    this.scrollable = true,
    this.center = false,
    this.childPad = true,
    super.key,
  });

  final Widget body;
  final Widget? header;
  final Widget? sidebar;
  final bool translucent;
  final bool scrollable;
  final bool center;
  final bool childPad;

  Widget _buildBody(BuildContext context) {
    // Center mode: wrap in scrollable centered layout
    if (center) {
      return LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(child: body),
          ),
        ),
      );
    }

    // Default scrollable mode
    if (!scrollable) {
      return body;
    }

    return SafeArea(child: SingleChildScrollView(child: body));
  }

  @override
  Widget build(BuildContext context) {
    var wrappedBody = _buildBody(context);

    // On mobile (non-multiPanel), wrap in ModalProvider so modals are within FScaffold context
    // This allows bottom sheets to use useSafeArea properly
    if (!context.isMultiPanel) {
      wrappedBody = ModalProvider(child: wrappedBody);
    }

    // Force forui default text style on the scaffold's content. The
    // MaterialApp.router-level DefaultTextStyle override (see app.dart)
    // resolves correctly for most descendants, but some entry points
    // (e.g. mobile headers, Material-wrapped subtrees) end up
    // inheriting MaterialApp's internal `_errorTextStyle` (yellow
    // double-underline) when their nearest DefaultTextStyle is supplied
    // by a Material widget rather than our app-level wrap. Repeating
    // the wrap here, with an explicit `decoration: TextDecoration.none`,
    // guarantees every scaffold-hosted page draws clean text.
    wrappedBody = DefaultTextStyle(
      style: context.theme.typography.md.copyWith(
        color: context.theme.colors.foreground,
        decoration: TextDecoration.none,
      ),
      child: wrappedBody,
    );

    // On Windows in single-panel mode, when no header is provided, add a minimal
    // drag bar with app name. In multi-panel mode, UnifiedHeader handles dragging.
    final effectiveHeader =
        header ?? (Platform.instance.isWindows && !context.isMultiPanel
            ? _WindowsDragBar()
            : null);

    final scaffold = FScaffold(
      header: effectiveHeader,
      sidebar: sidebar,
      childPad: childPad,
      child: wrappedBody,
    );

    final Widget result = PlatformBuilder(
      androidBuilder: (_) => material.Material(child: scaffold),
      webBuilder: (_) => material.Material(child: scaffold),
      builder: (_) => Directionality(
        textDirection: TextDirection.ltr,
        child: material.Material(
          color: translucent
              ? material.Colors.transparent
              : context.theme.colors.background,
          child: scaffold,
        ),
      ),
    );

    // When this page is the content of a corner-clipped panel (the right-hand
    // thread panel), round its corners *here* — below the panel's nested
    // navigator — rather than at the panel level. The panel deliberately
    // leaves the navigator unclipped so thread-page tooltips can escape its
    // edges; clipping the page content here keeps the header/background rounded
    // into the corners without trapping those overlays. Null (single-panel and
    // every other layout) leaves the content unclipped.
    final clipRadius = PanelContentClip.maybeOf(context);
    if (clipRadius == null) return result;
    return ClipRSuperellipse(
      borderRadius: clipRadius,
      clipBehavior: Clip.antiAlias,
      child: result,
    );
  }
}

/// Minimal draggable title bar for Windows pages that don't have a Header.
class _WindowsDragBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final toolbarPadding = Window.toolbarPadding.resolve(TextDirection.ltr);
    return FTheme(
      data: darkenTheme(context, context.theme, context.colour, steps: 2),
      child: Builder(
        builder: (context) => DecoratedBox(
          decoration: BoxDecoration(
            color: context.theme.colors.background,
            border: Border(
              bottom: BorderSide(
                color: context.theme.colors.border,
                width: 0.5,
              ),
            ),
          ),
          child: DragToMoveArea(
            child: SizedBox(
              height: Window.toolbarHeight,
              child: Padding(
                padding: EdgeInsets.only(left: 12, right: toolbarPadding.right),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Plot',
                    style: context.theme.typography.sm.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
