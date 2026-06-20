import 'dart:async';
import 'dart:typed_data';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/api/network_exception.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/image_utils.dart';

import 'logging.dart';
import 'note_action.dart';

/// A file picked from local storage (file picker, camera, clipboard) before it
/// has been uploaded. The uploader builds an optimistic placeholder from this
/// and uploads in the background.
///
/// Provide [bytes] when they are already in memory (web picks, camera captures,
/// pasted images, and native image picks the caller pre-read for previewing).
/// Provide [filePath] for native picks that should stream from disk during
/// upload (typically non-image files, where no inline preview is shown).
/// [mimeType] is provisional (usually extension-derived); the server's response
/// is authoritative once the upload completes.
class LocalAttachment {
  const LocalAttachment({
    required this.fileName,
    required this.mimeType,
    required this.fileSize,
    this.bytes,
    this.filePath,
  });

  final String fileName;
  final String mimeType;
  final int fileSize;
  final Uint8List? bytes;
  final String? filePath;

  bool get isImage => mimeType.startsWith('image/');
}

/// Signature of [api.uploadFile], injectable so the coordinator can be tested
/// without the network.
typedef UploadFn = Future<Map<String, dynamic>> Function({
  required String filePath,
  required String fileName,
  required String priorityId,
  Uint8List? bytes,
});

/// Signature of [getImageDimensions], injectable for tests.
typedef GetDimensionsFn = Future<(int, int)?> Function(Uint8List bytes);

bool _alwaysMounted() => true;

/// Coordinates optimistic attachment uploads for the note editor.
///
/// On [attachAll] it inserts a placeholder [FileUserAction] (with a
/// `__pending_…` id) into the editor's action list immediately — so the preview
/// appears without waiting on the network — caches image bytes so the thumbnail
/// renders from local data, then uploads each file in the background and swaps
/// the placeholder for the real attachment once the server returns a file id.
///
/// The coordinator does not own the action list: it reads it via [getActions]
/// and writes it via [setActions], so user edits (e.g. removing an attachment
/// mid-upload) stay authoritative. It tracks in-flight uploads so the editor can
/// [drainPending] before publishing — guaranteeing a `__pending_` id is never
/// persisted to a non-draft note.
///
/// New-thread mode routes [setActions] through `onDraftChanged`, whose round
/// trip has a one-frame read staleness. A single-file upload (the common case,
/// and what pasted images have always relied on) tolerates this because the
/// swap happens after a network round trip. Batching the placeholder insert
/// (one [setActions] for all picked files) keeps multi-select correct, and
/// per-file swaps are spaced by independent upload completions.
class AttachmentUploader {
  AttachmentUploader({
    required this.getPriorityId,
    required this.getActions,
    required this.setActions,
    required this.onError,
    this.upload = api.uploadFile,
    this.getDimensions = getImageDimensions,
    this.isMounted = _alwaysMounted,
  });

  final String Function() getPriorityId;
  final List<UserAction> Function() getActions;
  final void Function(List<UserAction> actions) setActions;
  final void Function(String message) onError;
  final UploadFn upload;
  final GetDimensionsFn getDimensions;
  final bool Function() isMounted;

  /// In-flight uploads keyed by their pending id, removed when each settles.
  final Map<String, Future<void>> _pending = <String, Future<void>>{};

  /// What each pending id resolved to: the uploaded [FileUserAction] on success,
  /// or `null` if the upload failed. Lets [resolvePending] clean a stale action
  /// snapshot at publish time, independent of when live swaps propagate to the
  /// draft. Keyed by the original pending id; entries persist for the editor's
  /// lifetime (placeholders are tiny).
  final Map<String, FileUserAction?> _resolved = <String, FileUserAction?>{};

  /// Monotonic counter for collision-free pending ids within a synchronous
  /// batch (and across the session).
  static int _seq = 0;

  bool get hasPending => _pending.isNotEmpty;

  /// Insert placeholders for [items] immediately and upload each in the
  /// background. Returns synchronously after the placeholders are inserted; the
  /// uploads continue via [drainPending]-trackable futures.
  void attachAll(List<LocalAttachment> items) {
    if (items.isEmpty) return;

    final placeholders = <UserAction>[];
    final pendingIds = <String>[];
    for (final item in items) {
      final pendingId = '__pending_${_seq++}';
      pendingIds.add(pendingId);
      placeholders.add(FileUserAction(
        fileId: pendingId,
        fileName: item.fileName,
        fileSize: item.fileSize,
        mimeType: item.mimeType,
      ));
      if (item.isImage && item.bytes != null) {
        FilePreviewCache.put(pendingId, item.bytes!);
      }
    }

    // One write for the whole batch: sequential per-item writes would each read
    // a stale list in new-thread mode and clobber the previous placeholder.
    setActions([...getActions(), ...placeholders]);

    for (var i = 0; i < items.length; i++) {
      final pendingId = pendingIds[i];
      _pending[pendingId] = _uploadOne(items[i], pendingId);
    }
  }

  /// Wait for every in-flight upload to settle. Afterwards the action list holds
  /// only real attachments (failed/removed placeholders are gone), so callers
  /// may publish without leaking a `__pending_` id.
  Future<void> drainPending() => Future.wait(_pending.values.toList());

  /// Resolve every `__pending_` placeholder in [actions] to its uploaded form,
  /// waiting for in-flight uploads first. A placeholder is replaced by the real
  /// attachment if its upload succeeded, and dropped if it failed or is unknown
  /// (e.g. a draft restored from a prior session). Non-pending actions are kept
  /// untouched and in order.
  ///
  /// Callers pass the action list they are about to publish (which may be a
  /// stale `widget.draft` snapshot that hasn't seen the live swaps yet); this
  /// guarantees no `__pending_` id is ever persisted to a non-draft note.
  Future<List<UserAction>> resolvePending(List<UserAction> actions) async {
    await drainPending();
    final result = <UserAction>[];
    for (final action in actions) {
      if (action is FileUserAction && action.fileId.startsWith('__pending_')) {
        final real = _resolved[action.fileId];
        if (real != null) result.add(real);
        // null or absent → the upload failed or never completed; drop it rather
        // than publish a broken file id.
      } else {
        result.add(action);
      }
    }
    return result;
  }

  Future<void> _uploadOne(LocalAttachment item, String pendingId) async {
    try {
      // Start the upload first (the network is the slow part); image
      // dimensions are only needed to build the final action, so compute them
      // after the upload returns rather than delaying the request.
      final response = await upload(
        filePath: item.filePath ?? '',
        fileName: item.fileName,
        priorityId: getPriorityId(),
        bytes: item.bytes,
      );

      if (!isMounted()) {
        FilePreviewCache.evict(pendingId);
        return;
      }

      int? imageWidth;
      int? imageHeight;
      if (item.isImage && item.bytes != null) {
        final dims = await getDimensions(item.bytes!);
        imageWidth = dims?.$1;
        imageHeight = dims?.$2;
      }

      if (!isMounted()) {
        _resolved[pendingId] = null;
        FilePreviewCache.evict(pendingId);
        return;
      }

      final realFileId = response['fileId'] as String;
      final realAction = FileUserAction(
        fileId: realFileId,
        fileName: response['fileName'] as String,
        fileSize: response['fileSize'] as int,
        mimeType: response['mimeType'] as String,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
      );
      // Record the resolution before touching the live list so a publish that
      // reads a stale snapshot still swaps this placeholder correctly, even if
      // the live swap below can't find it.
      _resolved[pendingId] = realAction;

      FilePreviewCache.rekey(pendingId, realFileId);

      final actions = getActions();
      var replaced = false;
      final updated = actions.map((a) {
        if (!replaced && a is FileUserAction && a.fileId == pendingId) {
          replaced = true;
          return realAction;
        }
        return a;
      }).toList();
      if (!replaced) {
        // The user removed the placeholder mid-upload — drop the cached bytes.
        // The just-uploaded file is orphaned (server-side cleanup).
        FilePreviewCache.evict(realFileId);
        return;
      }
      setActions(updated);
    } on NetworkException {
      _resolved[pendingId] = null;
      _removePending(pendingId);
      onError("You're offline. Please try again when connected.");
    } catch (e, t) {
      _resolved[pendingId] = null;
      _removePending(pendingId);
      log.warning('Failed to upload attachment: ${item.fileName}', e, t);
      Tracker.captureException(e, t);
      onError('Failed to upload ${item.fileName}.');
    } finally {
      _pending.remove(pendingId);
    }
  }

  void _removePending(String pendingId) {
    FilePreviewCache.evict(pendingId);
    if (!isMounted()) return;
    final actions = getActions();
    final filtered = actions
        .where((a) => !(a is FileUserAction && a.fileId == pendingId))
        .toList();
    if (filtered.length != actions.length) setActions(filtered);
  }
}
