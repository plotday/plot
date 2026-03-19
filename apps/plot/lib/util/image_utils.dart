import 'dart:typed_data';
import 'dart:ui' as ui;

/// Decodes the intrinsic pixel dimensions of an image from its raw bytes.
/// Returns `(width, height)` or `null` if decoding fails.
Future<(int, int)?> getImageDimensions(Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final result = (frame.image.width, frame.image.height);
    frame.image.dispose();
    codec.dispose();
    return result;
  } catch (_) {
    return null;
  }
}
