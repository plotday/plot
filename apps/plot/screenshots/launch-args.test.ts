import { test } from 'node:test';
import assert from 'node:assert/strict';
import { dartArgs } from './launch-args.ts';

test('windows platform gets --emulate-windows', () => {
  const args = dartArgs('S1', 'light', 'windows');
  assert.ok(args.includes('--emulate-windows'));
  assert.ok(args.includes('--profile=screenshots-windows'));
  assert.ok(args.includes('--scene=S1'));
});

test('non-windows platforms do not get --emulate-windows', () => {
  assert.ok(!dartArgs('S1', 'light', 'macos').includes('--emulate-windows'));
});
