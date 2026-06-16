import { test } from 'node:test';
import assert from 'node:assert/strict';
import { heroClips } from './geometry.ts';

test('heroClips splits a double-wide canvas into two equal slots', () => {
  const clips = heroClips([1290, 2796]);
  assert.equal(clips.length, 2);
  assert.deepEqual(clips[0], { x: 0, y: 0, width: 1290, height: 2796 });
  assert.deepEqual(clips[1], { x: 1290, y: 0, width: 1290, height: 2796 });
});
