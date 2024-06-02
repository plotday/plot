import 'package:flutter/widgets.dart';
import 'package:url_launcher/link.dart' as url_launcher;

// import 'style.dart';
import 'tapable.dart';

class Link extends StatelessWidget {
  const Link({required this.child, required this.uri, super.key});

  final Uri uri;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return url_launcher.Link(
      uri: uri,
      builder: (BuildContext context, url_launcher.FollowLink? followLink) =>
          Tapable(
        onTap: followLink!,
        child: child,
      ),
    );
  }
}
