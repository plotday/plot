/// Builds the URL for downloading a note attachment's bytes.
///
/// When [width] is provided, a `?w=<width>` query param requests a resized
/// inline preview (server-side WebP transform). When omitted, the URL returns
/// the full-size original (used by tap-to-zoom and the download button).
Uri buildFileBytesUri(String apiRoot, String fileId, {int? width}) {
  final base = '$apiRoot/files/$fileId';
  if (width == null) return Uri.parse(base);
  return Uri.parse('$base?w=$width');
}

/// Builds the URL for the connector fileRef resolver
/// (`GET /app/files/ref/:noteId/:actionIndex`).
///
/// [apiRoot] already includes the `/app` mount, so this appends only
/// `/files/ref/...` — never a second `/app` (which would 404 as a route miss).
Uri buildFileRefUri(String apiRoot, String noteId, int actionIndex) {
  return Uri.parse('$apiRoot/files/ref/$noteId/$actionIndex');
}
