import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:forui/forui.dart';
import 'package:platform_builder/platform_builder.dart';

import 'bottom_navigation_provider.dart';
import 'modal.dart';
import 'package:plot/state/layout.dart';

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
    final scaffold = FScaffold(
      header: header,
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
        child: Container(
          color: translucent ? null : context.theme.colors.background,
          child: scaffold,
        ),
      ),
    );
  }
}
