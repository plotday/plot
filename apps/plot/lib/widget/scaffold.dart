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

    // On Windows the native title bar is hidden, so the only way to move the
    // frameless window is a Flutter drag region. When a page supplies no
    // header of its own we add a minimal drag bar with the app name — UNLESS
    // an ancestor panel shell already provides a draggable [UnifiedHeader]
    // strip above this page (the signed-in multi-panel layout marks its
    // subtree with [WindowDragProvider]).
    //
    // In single-panel mode there is never a shell header above a bare page,
    // so the fallback always applies there. In multi-panel mode it applies
    // only to pages rendered OUTSIDE the panel shell — notably the pre-sign-in
    // pages (sign-in, loading, email), which render at multi-panel width but
    // have no [UnifiedHeader], and would otherwise leave the window impossible
    // to drag.
    final needsWindowsDragBar =
        Platform.instance.isWindows &&
        (!context.isMultiPanel || !WindowDragProvider.isProvided(context));
    final effectiveHeader =
        header ?? (needsWindowsDragBar ? _WindowsDragBar() : null);

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
    //
    // ClipRRect, not ClipRSuperellipse: on iPad the superellipse clip leaves
    // a dark fringe hugging the panel's outer corner curves (verified by
    // toggling just this clip). The circular arc sits a hair inside the
    // panel's superellipse background, so the difference hides as a sub-pixel
    // background-coloured sliver at the corners.
    final clipRadius = PanelContentClip.maybeOf(context);
    if (clipRadius == null) return result;
    return ClipRRect(
      borderRadius: clipRadius,
      clipBehavior: Clip.antiAlias,
      child: result,
    );
  }
}

/// Marks a subtree where an ancestor already supplies the OS window-drag
/// handle — a [UnifiedHeader]/[DragToMoveArea] strip at the top of the panel
/// shell. A [Scaffold] rendered below this in multi-panel mode therefore
/// skips its own [_WindowsDragBar] fallback: the shell header is what the
/// user grabs to move the frameless Windows window.
///
/// Pages shown OUTSIDE the panel shell (the sign-in / loading / email pages,
/// which render at multi-panel width but have no [UnifiedHeader] above them)
/// are not wrapped in this marker, so they still get the fallback drag bar —
/// without it the frameless window has no draggable region at all before
/// sign-in.
class WindowDragProvider extends InheritedWidget {
  const WindowDragProvider({
    required this.provided,
    required super.child,
    super.key,
  });

  /// Whether an ancestor supplies a window-drag handle.
  final bool provided;

  /// True when an enclosing [WindowDragProvider] declares that a drag handle
  /// is already present above the calling widget.
  static bool isProvided(BuildContext context) {
    final provider = context
        .dependOnInheritedWidgetOfExactType<WindowDragProvider>();
    return provider?.provided ?? false;
  }

  @override
  bool updateShouldNotify(WindowDragProvider oldWidget) =>
      provided != oldWidget.provided;
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
