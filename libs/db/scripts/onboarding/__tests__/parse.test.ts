// libs/db/scripts/onboarding/__tests__/parse.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { parseThreadFile } from "../parse.ts";

const SAMPLE = `---
key: priorities
title: Create your initial focuses
preview: Focuses are contexts for focus.
state:
  active: true
  importance: 90
---

## note: intro
Focuses are contexts for focus, often roles and goals.

Second paragraph.

## note: todo
Create your first focus.
`;

test("parseThreadFile reads frontmatter, order, notes", () => {
  const t = parseThreadFile("02-priorities.md", SAMPLE);
  assert.equal(t.key, "priorities");
  assert.equal(t.order, 2);
  assert.equal(t.title, "Create your initial focuses");
  assert.equal(t.preview, "Focuses are contexts for focus.");
  assert.equal(t.state.active, true);
  assert.equal(t.state.importance, 90);
  assert.equal(t.state.dateOffset, null);
  assert.equal(t.notes.length, 2);
  assert.equal(t.notes[0].key, "intro");
  assert.equal(
    t.notes[0].content,
    "Focuses are contexts for focus, often roles and goals.\n\nSecond paragraph.",
  );
  assert.equal(t.notes[1].key, "todo");
  assert.equal(t.notes[1].content, "Create your first focus.");
});

test("state defaults when omitted", () => {
  const t = parseThreadFile(
    "01-welcome.md",
    `---\nkey: welcome\ntitle: Hi\npreview: P\n---\n\n## note: intro\nBody.\n`,
  );
  assert.equal(t.state.active, false);
  assert.equal(t.state.importance, null);
  assert.equal(t.state.dateOffset, null);
  assert.equal(t.order, 1);
});
