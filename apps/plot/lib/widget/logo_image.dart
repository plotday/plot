import 'dart:typed_data';

import 'package:flutter_svg/flutter_svg.dart';
import 'package:plot/util/logo_cache.dart';
import 'package:plot/widget/widget.dart';

/// Displays a logo image from a URL with in-memory caching.
///
/// Always reserves [size]x[size] space to prevent layout shifts.
/// Uses [LogoCache] so the same URL is downloaded only once across all widgets.
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
    return SizedBox(
      width: size,
      height: size,
      child: LogoCache.isCached(url)
          ? _buildImage(LogoCache.getSync(url))
          : FutureBuilder<Uint8List?>(
              future: LogoCache.get(url),
              builder: (context, snapshot) => _buildImage(snapshot.data),
            ),
    );
  }

  Widget _buildImage(Uint8List? data) {
    if (data == null) return fallback ?? const SizedBox.shrink();
    if (LogoCache.isSvg(url)) {
      return SvgPicture.memory(data, width: size, height: size);
    }
    return Image.memory(data, width: size, height: size, fit: BoxFit.contain);
  }
}
