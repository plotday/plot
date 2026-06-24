import { test } from "node:test";
import assert from "node:assert/strict";

import { validateFragment } from "./check-updates-fragments.mjs";

test("valid fragment has no errors", () => {
  assert.deepEqual(validateFragment("### Fixes\n\n- a real fix\n"), []);
});

test("flags a missing ### heading", () => {
  const errors = validateFragment("- a bullet with no section\n");
  assert.ok(errors.some((e) => /### section heading/.test(e)));
});

test("flags a missing bullet", () => {
  const errors = validateFragment("### Fixes\n\n");
  assert.ok(errors.some((e) => /- bullet/.test(e)));
});

test("flags a stray ## top-level heading", () => {
  const errors = validateFragment("## Next release\n\n### Fixes\n\n- x\n");
  assert.ok(errors.some((e) => /## top-level heading/.test(e)));
});
