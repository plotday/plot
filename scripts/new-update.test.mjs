import { test } from "node:test";
import assert from "node:assert/strict";

import { slugify, randomId, fragmentTemplate } from "./new-update.mjs";

test("slugify lowercases, strips punctuation, hyphenates", () => {
  assert.equal(slugify("Email link fix!"), "email-link-fix");
  assert.equal(slugify("  Multiple   spaces  "), "multiple-spaces");
});

test("randomId is six lowercase alphanumerics", () => {
  assert.match(randomId(), /^[a-z0-9]{6}$/);
});

test("fragmentTemplate is an empty Fixes bullet", () => {
  assert.equal(fragmentTemplate(), "### Fixes\n\n- \n");
});
