import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';
import 'package:plot/state/priority.dart';

void main() {
  Priority focus(String title, {bool isInbox = false}) => Priority.fromStore(
        PriorityRow(
          id: Uuid.generate(),
          createdBy: Uuid.generate(),
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 1),
          title: title,
          path: Path(title.toLowerCase()),
          order: const Order(0),
          unread: false,
          role: 'member',
          isInbox: isInbox,
          isFyi: false,
          attentionWindowSet: false,
          seeWithinSet: false,
          earlyNotificationsEnabledSet: false,
          notifyWindowSet: false,
        ),
        draft: true,
      );

  // A draft note that doesn't reach into the [Base] injector for `actorId`
  // (which is unconfigured in this bare unit test). Supplying it lets the
  // [PriorityState] factory still synthesize the draft *thread* from the
  // resolved context / fallback — exactly the behaviour under test — without
  // also calling the `Base`-dependent `Note.draft`.
  Note draftNoteFor(Thread draft) => Note(
        id: Uuid.generate(),
        threadId: draft.id,
        authorId: ActorId(Uuid.generate()),
        draft: true,
        createdAt: DateTime(2026, 1, 1),
        sourceCreatedAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );

  test('everything state: null context, files draft under the fallback', () {
    final inbox = focus('Inbox', isInbox: true);
    // The factory builds the draft from `draftFallbackPriority` because
    // `context` is null. Supply only the draft note so it skips `Note.draft`.
    final draft = Thread(priority: inbox, draft: true);
    final state = PriorityState(
      context: null,
      everything: true,
      draftFallbackPriority: inbox,
      draft: draft,
      draftNote: draftNoteFor(draft),
    );
    expect(state.context, isNull);
    expect(state.everything, isTrue);
    expect(state.draft.priority.id, inbox.id);
  });

  test(
      'everything state synthesizes its draft from the fallback when no draft '
      'is supplied', () {
    final inbox = focus('Inbox', isInbox: true);
    // No explicit draft: the factory must synthesize one whose priority is the
    // fallback. A note is still supplied to avoid the `Base`-dependent
    // `Note.draft`.
    final probe = Thread(priority: inbox, draft: true);
    final state = PriorityState(
      context: null,
      everything: true,
      draftFallbackPriority: inbox,
      draftNote: draftNoteFor(probe),
    );
    expect(state.context, isNull);
    expect(state.everything, isTrue);
    expect(state.draft.priority.id, inbox.id);
  });

  test('focus state: non-null context, invariant holds', () {
    final work = focus('Work');
    final draft = Thread(priority: work, draft: true);
    final state = PriorityState(
      context: work,
      everything: false,
      draft: draft,
      draftNote: draftNoteFor(draft),
    );
    expect(state.context, isNotNull);
    expect(state.everything, isFalse);
    expect(state.draft.priority.id, work.id);
  });

  test('focus state synthesizes its draft from the context', () {
    final work = focus('Work');
    final probe = Thread(priority: work, draft: true);
    final state = PriorityState(
      context: work,
      everything: false,
      draftNote: draftNoteFor(probe),
    );
    expect(state.draft.priority.id, work.id);
  });

  test('invariant is asserted: everything without a null context throws', () {
    final work = focus('Work');
    final draft = Thread(priority: work, draft: true);
    expect(
      () => PriorityState(
        context: null,
        everything: false,
        draftFallbackPriority: work,
        draft: draft,
        draftNote: draftNoteFor(draft),
      ),
      throwsA(isA<AssertionError>()),
    );
  });

  test('invariant is asserted: a non-null context with everything throws', () {
    final work = focus('Work');
    final draft = Thread(priority: work, draft: true);
    expect(
      () => PriorityState(
        context: work,
        everything: true,
        draft: draft,
        draftNote: draftNoteFor(draft),
      ),
      throwsA(isA<AssertionError>()),
    );
  });
}
