import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:forui/forui.dart';
import 'package:platform_builder/platform_builder.dart';
import 'package:window_manager/window_manager.dart';

import 'bottom_navigation_provider.dart';
import 'modal.dart';
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
      return SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: MediaQuery.of(context).size.height,
          ),
          child: Center(child: body),
        ),
      );
    }

    // Default scrollable mode
    if (!scrollable) {
      return body;
    }

    return SafeArea(child: SingleChildScrollView(child: body));
  }

  Widget? _buildFooter(BuildContext context) {
    final config = BottomNavigationProvider.of(context);
    if (config == null) {
      return null;
    }

    return FBottomNavigationBar(
      index: config.currentIndex,
      onChange: config.onChange,
      children: config.items,
    );
  }

  @override
  Widget build(BuildContext context) {
    var wrappedBody = _buildBody(context);

    // On mobile (non-multiPanel), wrap in ModalProvider so modals are within FScaffold context
    // This allows bottom sheets to use useSafeArea properly
    if (!context.isMultiPanel) {
      wrappedBody = ModalProvider(child: wrappedBody);
    }

    final footer = _buildFooter(context);

    // On Windows, when no header is provided, add a minimal drag bar with app name
    final effectiveHeader = header ?? (Platform.instance.isWindows
        ? _WindowsDragBar()
        : null);

    final scaffold = FScaffold(
      header: effectiveHeader,
      sidebar: sidebar,
      footer: footer,
      childPad: childPad,
      child: wrappedBody,
    );

    return PlatformBuilder(
      androidBuilder: (_) => material.Material(child: scaffold),
      webBuilder: (_) => material.Material(child: scaffold),
      builder: (_) => Directionality(
        textDirection: TextDirection.ltr,
        child: material.Material(
          color: translucent ? material.Colors.transparent : context.theme.colors.background,
          child: scaffold,
        ),
      ),
    );
  }
}

/// Minimal draggable title bar for Windows pages that don't have a Header.
class _WindowsDragBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final toolbarPadding = Window.toolbarPadding.resolve(TextDirection.ltr);
    return FAnimatedTheme(
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
                padding: EdgeInsets.only(
                  left: 12,
                  right: toolbarPadding.right,
                ),
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
