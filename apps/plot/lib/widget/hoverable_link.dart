import 'package:flutter/widgets.dart';
import 'package:url_launcher/link.dart' as url_launcher;
import 'link.dart';

class HoverableLink extends StatefulWidget {
  const HoverableLink({
    required this.text,
    required this.uri,
    this.color,
    this.target,
    super.key,
  });

  final String text;
  final Uri uri;
  final Color? color;
  final url_launcher.LinkTarget? target;

  @override
  State<HoverableLink> createState() => _HoverableLinkState();
}

class _HoverableLinkState extends State<HoverableLink> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Link(
        uri: widget.uri,
        target: widget.target,
        child: Text(
          widget.text,
          style: TextStyle(
            color: widget.color,
            decoration: _isHovered
                ? TextDecoration.underline
                : TextDecoration.none,
            decorationColor: widget.color,
          ),
        ),
      ),
    );
  }
}
