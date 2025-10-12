import 'package:flutter/widgets.dart';
import 'link.dart';

class HoverableLink extends StatefulWidget {
  const HoverableLink({
    required this.text,
    required this.uri,
    this.color = const Color(0xFF6B7280),
    this.fontSize = 12,
    super.key,
  });

  final String text;
  final Uri uri;
  final Color color;
  final double fontSize;

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
        child: Text(
          widget.text,
          style: TextStyle(
            fontSize: widget.fontSize,
            color: widget.color,
            decoration: _isHovered ? TextDecoration.underline : TextDecoration.none,
            decorationColor: widget.color,
          ),
        ),
      ),
    );
  }
}
