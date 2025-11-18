import 'package:flutter/widgets.dart';
import 'package:url_launcher/link.dart' as url_launcher;

import 'tapable.dart';

class Link extends StatelessWidget {
  const Link({
    required this.child,
    required this.uri,
    this.target,
    super.key,
  });

  final Uri uri;
  final Widget child;
  final url_launcher.LinkTarget? target;

  @override
  Widget build(BuildContext context) {
    return url_launcher.Link(
      uri: uri,
      target: target ?? url_launcher.LinkTarget.defaultTarget,
      builder: (BuildContext context, url_launcher.FollowLink? followLink) =>
          Tapable(
        onTap: followLink!,
        child: child,
      ),
    );
  }
}
