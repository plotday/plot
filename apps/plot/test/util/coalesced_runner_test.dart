import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/util/async.dart';

void main() {
  test('concurrent runs share one execution', () async {
    final runner = CoalescedRunner();
    var executions = 0;
    final gate = Completer<void>();

    Future<void> action() async {
      executions++;
      await gate.future;
    }

    final first = runner.run(action);
    final second = runner.run(action); // joins in-flight run
    expect(runner.isRunning, isTrue);

    gate.complete();
    await Future.wait([first, second]);
    expect(executions, 1);
    expect(runner.isRunning, isFalse);
  });

  test('sequential runs execute each time', () async {
    final runner = CoalescedRunner();
    var executions = 0;
    await runner.run(() async => executions++);
    await runner.run(() async => executions++);
    expect(executions, 2);
  });

  test('errors propagate to every joined caller, then reset', () async {
    final runner = CoalescedRunner();
    final gate = Completer<void>();
    Future<void> failing() async {
      await gate.future;
      throw StateError('boom');
    }

    final first = runner.run(failing);
    final second = runner.run(failing);
    gate.complete();
    await expectLater(first, throwsStateError);
    await expectLater(second, throwsStateError);
    // A later run starts fresh.
    var ran = false;
    await runner.run(() async => ran = true);
    expect(ran, isTrue);
  });

  test('synchronously-completing action does not wedge the runner', () async {
    final runner = CoalescedRunner();
    await runner.run(() async {});
    expect(runner.isRunning, isFalse);
    var ran = false;
    await runner.run(() async => ran = true);
    expect(ran, isTrue);
  });

  test('waitIdle returns immediately when idle', () async {
    final runner = CoalescedRunner();
    expect(runner.isRunning, isFalse);
    // Should not hang — no run is in flight.
    await runner.waitIdle().timeout(const Duration(seconds: 1));
  });

  test(
    'waitIdle completes only after an in-flight run finishes',
    () async {
      final runner = CoalescedRunner();
      final gate = Completer<void>();
      var actionCompleted = false;

      final runFuture = runner.run(() async {
        await gate.future;
        actionCompleted = true;
      });

      var waitIdleCompleted = false;
      final waitIdleFuture = runner.waitIdle().then((_) {
        waitIdleCompleted = true;
      });

      // Give the event loop a chance to run pending microtasks; waitIdle
      // must still be blocked because the gated run hasn't finished.
      await Future<void>.delayed(Duration.zero);
      expect(waitIdleCompleted, isFalse);
      expect(actionCompleted, isFalse);

      gate.complete();
      await runFuture;
      await waitIdleFuture;
      expect(actionCompleted, isTrue);
      expect(waitIdleCompleted, isTrue);
    },
  );

  test('waitIdle does not throw when the in-flight run fails', () async {
    final runner = CoalescedRunner();
    final gate = Completer<void>();
    Future<void> failing() async {
      await gate.future;
      throw StateError('boom');
    }

    final runFuture = runner.run(failing);
    final waitIdleFuture = runner.waitIdle();

    gate.complete();
    await expectLater(runFuture, throwsStateError);
    // waitIdle must resolve normally even though the run it waited on threw.
    await waitIdleFuture.timeout(const Duration(seconds: 1));
    expect(runner.isRunning, isFalse);
  });
}
