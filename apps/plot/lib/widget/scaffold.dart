import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart' as macos;
import 'layout.dart';
import 'button.dart';

class ActionItem {
  const ActionItem({
    required this.icon,
    required this.label,
    this.showLabel = true,
    required this.onPressed,
  });
  final Widget icon;
  final String label;
  final bool showLabel;
  final VoidCallback onPressed;
}

class Scaffold extends StatefulWidget {
  const Scaffold({required this.body, this.title, this.actions, super.key});

  final Widget body;
  final Widget? title;
  final List<ActionItem>? actions;

  @override
  ScaffoldState createState() => ScaffoldState();
}

class ScaffoldState extends State<Scaffold> {
  final GlobalKey _toolbarKey = GlobalKey();
  EdgeInsetsGeometry _padding = EdgeInsets.zero;

  @override
  void initState() {
    super.initState();
    // Use post-frame callback to ensure layout is complete
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateToolbarPadding();
    });
  }

  void _updateToolbarPadding() {
    final RenderBox? renderBox =
        _toolbarKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox != null) {
      final pos = renderBox.localToGlobal(Offset.zero);
      setState(() {
        _padding = pos.dx == 0 && pos.dy == 0
            ? Layout.toolbarPadding
            : EdgeInsets.zero;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        final hasToolbar = widget.title != null || widget.actions != null;
        final topPadding = hasToolbar ? Layout.toolbarHeight : 0.0;

        return Stack(
          children: [
            Positioned(
              top: 0,
              width: width,
              height: height,
              child: Padding(
                padding: EdgeInsets.only(top: topPadding),
                child: widget.body,
              ),
            ),
            // Toolbar
            if (hasToolbar)
              Positioned(
                width: width,
                height: Layout.toolbarHeight,
                child: Builder(builder: (BuildContext context) {
                  Widget? backButton = ModalRoute.of(context)?.canPop != true
                      ? null
                      : Container(
                          width: 20.0,
                          alignment: Alignment.centerLeft,
                          child: macos.MacosBackButton(
                            fillColor: macos.MacosColors.transparent,
                            onPressed: () => Navigator.maybePop(context),
                          ),
                        );

                  return Padding(
                    key: _toolbarKey,
                    padding: _padding,
                    child: Row(
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              if (backButton != null) backButton,
                              if (widget.title != null)
                                Expanded(
                                  child: widget.title!,
                                ),
                            ],
                          ),
                        ),
                        Row(
                          children: (widget.actions ?? [])
                              .map(
                                (action) => IconButton(
                                  icon: action.icon,
                                  onPressed: action.onPressed,
                                ),
                              )
                              .toList(),
                        ),
                      ],
                    ),
                  );
                }),
              ),
          ],
        );
      },
    );
  }
}
