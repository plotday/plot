import 'package:flutter_test/flutter_test.dart';
import 'package:plot/command/note.dart';
import 'package:plot/store/store.dart';

final _selfId = ActorId.fromString('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

void main() {
  // Note.draft reads Base.actorId for the author, so a minimal Base must be
  // registered for the test environment.
  setUp(() {
    Base.initForTesting(_selfId);
  });

  tearDown(() {
    Base.removeForTesting();
  });

  test('ForwardNote is titled "Forward" with the forward icon', () {
    final note = Note.draft(threadId: ThreadId.generate())
        .copyWith(content: 'hello', draft: false);
    final cmd = ForwardNote(note);
    expect(cmd.title, 'Forward');
  });
}
