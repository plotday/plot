import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PLANS, capturesFor } from './manifest.ts';

test('windows plan targets MS Store at the Retina-capturable 2880x1800 with multipanel-windows framing', () => {
  const win = PLANS.find((p) => p.platform === 'windows');
  assert.ok(win, 'windows plan exists');
  assert.equal(win!.store, 'ms-store');
  assert.equal(win!.captureDevice, 'macos');
  assert.deepEqual(win!.resolution, [2880, 1800]);
  assert.ok(
    win!.slots.every((s) => s.framing === 'multipanel-windows'),
    'every slot uses multipanel-windows framing',
  );
});

test('windows plan captures five distinct scenes', () => {
  const win = PLANS.find((p) => p.platform === 'windows')!;
  assert.equal(capturesFor(win).length, 5);
});

test('windows plan uses the locked captions (mirrors macOS)', () => {
  const win = PLANS.find((p) => p.platform === 'windows')!;
  const captions = Object.fromEntries(win.slots.map((s) => [s.scene, s.headline]));
  assert.deepEqual(captions, {
    S1: 'All your work, ready for action',
    S2: 'Reply to anything without opening another app',
    S11: 'Drive it from the keyboard',
    S7: 'AI alongside your work — or off entirely',
    S8: 'Works with the tools you already use',
  });
  // multipanel-windows slots carry a headline only (no subhead).
  assert.ok(win.slots.every((s) => s.subhead === undefined));
});
