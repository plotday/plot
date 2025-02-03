import 'package:flutter/widgets.dart';
import 'window.dart';

class Scaffold extends StatefulWidget {
  const Scaffold({required this.body, this.header, super.key});

  final Widget body;
  final Widget? header;

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
            ? Window.toolbarPadding
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
        final hasHeader = widget.header != null;
        final topPadding = hasHeader ? Window.toolbarHeight : 0.0;

        return Stack(
          children: [
            // Body
            Positioned(
              top: 0,
              width: width,
              height: height,
              child: Padding(
                padding: EdgeInsets.only(top: topPadding),
                child: widget.body,
              ),
            ),
            // Header
            if (hasHeader)
              Positioned(
                top: 0,
                width: width,
                height: Window.toolbarHeight,
                child: Builder(builder: (BuildContext context) {
                  return Padding(
                    key: _toolbarKey,
                    padding: _padding,
                    child: widget.header!,
                  );
                }),
              ),
          ],
        );
      },
    );
  }
}
