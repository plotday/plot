import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/otp_prompt_controller.dart';
import 'package:plot/store/store.dart';

Note _note(String idHex, Cta cta, DateTime sent) {
  // Build a minimal valid Note. UUIDs are seeded deterministically from a
  // fixed base so the helper stays pure (no randomness, no DB).
  final id = Uuid.fromString('00000000-0000-0000-0000-$idHex');
  final threadId = Uuid.fromString('11111111-1111-1111-1111-111111111111');
  final authorId = ActorId.fromUuid(
    Uuid.fromString('22222222-2222-2222-2222-222222222222'),
  );
  return Note(
    id: id,
    threadId: threadId,
    authorId: authorId,
    draft: false,
    cta: cta,
    createdAt: sent,
    sourceCreatedAt: sent,
    updatedAt: sent,
  );
}

void main() {
  test('selects the latest in-window cta note', () {
    final now = DateTime.now();
    final c = OtpPromptController.forTest();
    c.onNotes([
      _note(
        '000000000001',
        const Cta(kind: CtaKind.otp, service: 'A', code: '111111', url: null),
        now.subtract(const Duration(minutes: 1)),
      ),
      _note(
        '000000000002',
        const Cta(kind: CtaKind.otp, service: 'B', code: '222222', url: null),
        now.subtract(const Duration(seconds: 5)),
      ),
    ], now: now);
    expect(c.current.value?.cta.service, 'B'); // latest wins
  });

  test('ignores notes older than 5 minutes', () {
    final now = DateTime.now();
    final c = OtpPromptController.forTest();
    c.onNotes([
      _note(
        '000000000001',
        const Cta(kind: CtaKind.otp, service: 'A', code: '111111', url: null),
        now.subtract(const Duration(minutes: 6)),
      ),
    ], now: now);
    expect(c.current.value, isNull);
  });

  test('dismissed cta does not reappear', () {
    final now = DateTime.now();
    final c = OtpPromptController.forTest();
    final n = _note(
      '000000000001',
      const Cta(kind: CtaKind.otp, service: 'A', code: '111111', url: null),
      now,
    );
    c.onNotes([n], now: now);
    c.dismiss();
    c.onNotes([n], now: now);
    expect(c.current.value, isNull);
  });
}
