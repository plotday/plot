// libs/db/scripts/onboarding/__tests__/snapshot.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { compileSnapshot, diffSnapshots } from "../snapshot.ts";
import type { OnboardingModel, ThreadDef } from "../model.ts";

const thread = (over: Partial<ThreadDef>): ThreadDef => ({
  key: "welcome",
  order: 1,
  title: "Welcome",
  preview: "P",
  state: { active: false, importance: null, dateOffset: null },
  notes: [{ key: "intro", content: "Hello" }],
  ...over,
});

const model = (global: ThreadDef[], perUser: ThreadDef[] = []): OnboardingModel => ({
  global,
  perUser,
});

test("identical models diff to no changes", () => {
  const a = compileSnapshot(model([thread({})]));
  const b = compileSnapshot(model([thread({})]));
  const d = diffSnapshots(a, b);
  assert.equal(d.hasChanges, false);
});

test("retitle is an upsert, not archive", () => {
  const prev = compileSnapshot(model([thread({})]));
  const next = compileSnapshot(model([thread({ title: "Welcome!" })]));
  const d = diffSnapshots(prev, next);
  assert.deepEqual(d.threadsUpserted, ["welcome"]);
  assert.deepEqual(d.threadsArchived, []);
});

test("removing a thread archives it", () => {
  const prev = compileSnapshot(model([thread({}), thread({ key: "twists", order: 2 })]));
  const next = compileSnapshot(model([thread({})]));
  const d = diffSnapshots(prev, next);
  assert.deepEqual(d.threadsArchived, ["twists"]);
});

test("note removal archives just the note", () => {
  const prev = compileSnapshot(
    model([thread({ notes: [{ key: "intro", content: "Hello" }, { key: "todo", content: "Do" }] })]),
  );
  const next = compileSnapshot(model([thread({ notes: [{ key: "intro", content: "Hello" }] })]));
  const d = diffSnapshots(prev, next);
  assert.deepEqual(d.notesArchived, ["welcome/todo"]);
  assert.deepEqual(d.threadsArchived, []);
});

test("per-user content change flips perUserChanged", () => {
  const prev = compileSnapshot(model([], [thread({ key: "welcome-user" })]));
  const next = compileSnapshot(
    model([], [thread({ key: "welcome-user", notes: [{ key: "intro", content: "Changed" }] })]),
  );
  const d = diffSnapshots(prev, next);
  assert.equal(d.perUserChanged, true);
  assert.equal(d.hasChanges, true);
});
