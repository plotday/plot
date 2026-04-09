import 'dart:typed_data';

import 'package:flutter_svg/flutter_svg.dart';
import 'package:plot/util/logo_cache.dart';
import 'package:plot/widget/widget.dart';

/// Displays a logo image from a URL with in-memory caching.
///
/// Uses [LogoCache] so the same URL is downloaded only once across all widgets.
/// Shows [fallback] when the image fails to load, or nothing if no fallback.
class LogoImage extends StatelessWidget {
  const LogoImage({
    super.key,
    required this.url,
    this.size = 16,
    this.fallback,
  });

  final String url;
  final double size;
  final Widget? fallback;

  @override
  Widget build(BuildContext context) {
    if (LogoCache.isCached(url)) {
      return _buildImage(LogoCache.getSync(url));
    }
    return FutureBuilder<Uint8List?>(
      future: LogoCache.get(url),
      builder: (context, snapshot) => _buildImage(snapshot.data),
    );
  }

  Widget _buildImage(Uint8List? data) {
    if (data == null) return fallback ?? const SizedBox.shrink();

    final Widget image;
    if (LogoCache.isSvg(url)) {
      image = SvgPicture.memory(data, width: size, height: size);
    } else {
      image = Image.memory(
        data,
        width: size,
        height: size,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => fallback ?? const SizedBox.shrink(),
      );
    }

    return SizedBox(
      width: size,
      height: size,
      child: Center(child: image),
    );
  }
}
