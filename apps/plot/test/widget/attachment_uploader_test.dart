import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:plot/api/network_exception.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/attachment_uploader.dart';
import 'package:plot/widget/note_action.dart';

/// Signature of the injectable uploader, matching `api.uploadFile`.
typedef _Upload = Future<Map<String, dynamic>> Function({
  required String filePath,
  required String fileName,
  required String priorityId,
  Uint8List? bytes,
});

void main() {
  late List<UserAction> actions;
  late List<String> errors;

  setUp(() {
    actions = <UserAction>[];
    errors = <String>[];
  });

  Uint8List bytesOf(List<int> b) => Uint8List.fromList(b);

  AttachmentUploader makeUploader(
    _Upload upload, {
    Future<(int, int)?> Function(Uint8List)? getDimensions,
    bool Function()? isMounted,
  }) {
    return AttachmentUploader(
      getPriorityId: () => 'prio-1',
      getActions: () => actions,
      setActions: (a) => actions = a,
      onError: errors.add,
      upload: upload,
      getDimensions: getDimensions ?? ((_) async => null),
      isMounted: isMounted ?? () => true,
    );
  }

  LocalAttachment image({String name = 'pic.png'}) => LocalAttachment(
        fileName: name,
        mimeType: 'image/png',
        fileSize: 3,
        bytes: bytesOf([1, 2, 3]),
      );

  LocalAttachment doc({String name = 'report.pdf'}) => LocalAttachment(
        fileName: name,
        mimeType: 'application/pdf',
        fileSize: 4,
        filePath: '/tmp/$name',
      );

  Map<String, dynamic> serverResponse(String id, LocalAttachment a) => {
        'fileId': id,
        'fileName': a.fileName,
        'fileSize': a.fileSize,
        'mimeType': a.mimeType,
      };

  group('attachAll — instant insert', () {
    test('inserts a pending placeholder synchronously, before upload resolves',
        () {
      final completer = Completer<Map<String, dynamic>>();
      final uploader = makeUploader(
        ({required filePath, required fileName, required priorityId, bytes}) =>
            completer.future,
      );

      uploader.attachAll([image()]);

      // The placeholder is present immediately — nothing awaited the upload.
      expect(actions, hasLength(1));
      final placeholder = actions.single as FileUserAction;
      expect(placeholder.fileId, startsWith('__pending_'));
      expect(placeholder.fileName, 'pic.png');
      expect(placeholder.isImage, isTrue);
      expect(uploader.hasPending, isTrue);

      completer.complete(serverResponse('real-1', image()));
    });

    test('caches image bytes under the pending id; a non-image caches nothing',
        () {
      final completer = Completer<Map<String, dynamic>>();
      final uploader = makeUploader(
        ({required filePath, required fileName, required priorityId, bytes}) =>
            completer.future,
      );

      uploader.attachAll([image(), doc()]);

      final placeholders = actions.cast<FileUserAction>();
      final imgId = placeholders.firstWhere((a) => a.isImage).fileId;
      final docId = placeholders.firstWhere((a) => !a.isImage).fileId;
      expect(FilePreviewCache.get(imgId), isNotNull);
      expect(FilePreviewCache.get(docId), isNull);

      completer.complete(serverResponse('x', image()));
    });
  });

  group('upload completion', () {
    test('swaps the placeholder for the server action and rekeys the cache',
        () async {
      final att = image();
      final uploader = makeUploader(
        ({required filePath, required fileName, required priorityId, bytes}) async =>
            serverResponse('real-1', att),
      );

      uploader.attachAll([att]);
      final pendingId = (actions.single as FileUserAction).fileId;
      await uploader.drainPending();

      expect(actions, hasLength(1));
      final real = actions.single as FileUserAction;
      expect(real.fileId, 'real-1');
      expect(FilePreviewCache.get('real-1'), isNotNull);
      expect(FilePreviewCache.get(pendingId), isNull);
      expect(uploader.hasPending, isFalse);
    });

    test('removes the placeholder and reports an error when the upload fails',
        () async {
      final uploader = makeUploader(
        ({required filePath, required fileName, required priorityId, bytes}) async =>
            throw const NetworkException(message: 'offline'),
      );

      uploader.attachAll([image()]);
      final pendingId = (actions.single as FileUserAction).fileId;
      await uploader.drainPending();

      expect(actions, isEmpty);
      expect(errors, isNotEmpty);
      expect(FilePreviewCache.get(pendingId), isNull);
      expect(uploader.hasPending, isFalse);
    });

    test('does not re-add a placeholder the user removed mid-upload', () async {
      final completer = Completer<Map<String, dynamic>>();
      final att = image();
      final uploader = makeUploader(
        ({required filePath, required fileName, required priorityId, bytes}) =>
            completer.future,
      );

      uploader.attachAll([att]);
      // The user removes the attachment before the upload resolves.
      actions = <UserAction>[];
      completer.complete(serverResponse('real-1', att));
      await uploader.drainPending();

      expect(actions, isEmpty);
      expect(FilePreviewCache.get('real-1'), isNull);
    });
  });

  group('drainPending — publish gate', () {
    test('waits for an in-flight upload and yields a list with no pending id',
        () async {
      final completer = Completer<Map<String, dynamic>>();
      final att = image();
      final uploader = makeUploader(
        ({required filePath, required fileName, required priorityId, bytes}) =>
            completer.future,
      );

      uploader.attachAll([att]);
      var drained = false;
      final drain = uploader.drainPending().then((_) => drained = true);

      // Still pending until the upload resolves.
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);

      completer.complete(serverResponse('real-1', att));
      await drain;

      expect(drained, isTrue);
      expect((actions.single as FileUserAction).fileId, 'real-1');
      expect(
        actions
            .whereType<FileUserAction>()
            .any((a) => a.fileId.startsWith('__pending_')),
        isFalse,
      );
    });

    test('drains to an action list without the attachment when upload failed',
        () async {
      final completer = Completer<Map<String, dynamic>>();
      final uploader = makeUploader(
        ({required filePath, required fileName, required priorityId, bytes}) =>
            completer.future,
      );

      uploader.attachAll([image()]);
      final drain = uploader.drainPending();
      completer.completeError(const NetworkException(message: 'offline'));
      await drain;

      expect(actions, isEmpty);
    });
  });

  group('multi-file', () {
    test('inserts all placeholders in one batch and resolves each independently',
        () async {
      final responses = <String, Completer<Map<String, dynamic>>>{};
      final uploader = makeUploader(
        ({required filePath, required fileName, required priorityId, bytes}) {
          final c = Completer<Map<String, dynamic>>();
          responses[fileName] = c;
          return c.future;
        },
      );

      final a = image(name: 'a.png');
      final b = image(name: 'b.png');
      final c = doc(name: 'c.pdf');
      uploader.attachAll([a, b, c]);

      expect(actions, hasLength(3));
      expect(
        actions.every(
          (x) => (x as FileUserAction).fileId.startsWith('__pending_'),
        ),
        isTrue,
      );

      responses['a.png']!.complete(serverResponse('id-a', a));
      responses['b.png']!.complete(serverResponse('id-b', b));
      responses['c.pdf']!.complete(serverResponse('id-c', c));
      await uploader.drainPending();

      final ids = actions.cast<FileUserAction>().map((x) => x.fileId).toList();
      expect(ids, containsAll(<String>['id-a', 'id-b', 'id-c']));
      expect(ids.any((id) => id.startsWith('__pending_')), isFalse);
    });
  });

  group('resolvePending — publish-time resolution of a stale snapshot', () {
    test('swaps placeholders to real actions and drops failed uploads',
        () async {
      final byName = <String, Completer<Map<String, dynamic>>>{
        'a.png': Completer<Map<String, dynamic>>(),
        'b.png': Completer<Map<String, dynamic>>(),
      };
      final uploader = makeUploader(
        ({required filePath, required fileName, required priorityId, bytes}) =>
            byName[fileName]!.future,
      );

      final a = image(name: 'a.png');
      final b = image(name: 'b.png');
      uploader.attachAll([a, b]);

      // A frozen snapshot that still shows both placeholders — exactly what a
      // finalize path reads from `widget.draft` while uploads are in flight.
      final stale = <UserAction>[...actions];

      byName['a.png']!.complete(serverResponse('id-a', a));
      byName['b.png']!.completeError(const NetworkException(message: 'offline'));

      final resolved = await uploader.resolvePending(stale);

      expect(resolved, hasLength(1));
      expect((resolved.single as FileUserAction).fileId, 'id-a');
    });

    test('keeps non-pending actions untouched and preserves order', () async {
      final uploader = makeUploader(
        ({required filePath, required fileName, required priorityId, bytes}) async =>
            serverResponse('id-a', image()),
      );

      final realPrior = FileUserAction(
        fileId: 'already-real',
        fileName: 'old.png',
        fileSize: 1,
        mimeType: 'image/png',
      );
      uploader.attachAll([image(name: 'a.png')]);
      final stale = <UserAction>[realPrior, ...actions];

      final resolved = await uploader.resolvePending(stale);

      expect(resolved, hasLength(2));
      expect((resolved[0] as FileUserAction).fileId, 'already-real');
      expect((resolved[1] as FileUserAction).fileId, 'id-a');
    });

    test('drops an unknown pending id (e.g. a draft restored from a prior '
        'session) rather than publishing it', () async {
      final uploader = makeUploader(
        ({required filePath, required fileName, required priorityId, bytes}) async =>
            serverResponse('x', image()),
      );

      final orphan = FileUserAction(
        fileId: '__pending_99999',
        fileName: 'ghost.png',
        fileSize: 1,
        mimeType: 'image/png',
      );

      final resolved = await uploader.resolvePending([orphan]);

      expect(resolved, isEmpty);
    });
  });
}
