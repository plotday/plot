import { test } from "node:test";
import assert from "node:assert/strict";
import { emitGlobalReconcile } from "../emit-global.ts";
import type { OnboardingModel, ThreadDef } from "../model.ts";

const thread = (over: Partial<ThreadDef>): ThreadDef => ({
  key: "welcome",
  order: 1,
  title: "Welcome to Plot!",
  preview: "Plot is your workspace.",
  state: { active: false, importance: null, dateOffset: null },
  notes: [{ key: "intro", content: "Body with ' apostrophe" }],
  ...over,
});
const model = (global: ThreadDef[]): OnboardingModel => ({ global, perUser: [] });

test("emits guarded DO block resolving system twist + updates topic", () => {
  const sql = emitGlobalReconcile(model([thread({})]), { archivedThreadKeys: [], archivedNoteKeys: [] });
  assert.match(sql, /DO \$\$/);
  assert.match(sql, /v_plot_twist_id/);
  assert.match(sql, /v_updates_topic_id/);
  assert.match(sql, /key = '@plot\.updates'/);
  // Atlas-robust early return when system rows aren't seeded yet.
  assert.match(sql, /IF v_plot_twist_id IS NULL OR v_updates_topic_id IS NULL THEN RETURN; END IF;/);
});

test("threads are system-instance authored, twist-iconed, topic-routed, no groups", () => {
  const sql = emitGlobalReconcile(model([thread({})]), { archivedThreadKeys: [], archivedNoteKeys: [] });
  assert.match(sql, /created_by, twist_id, icon, title, preview, key, topic_id, topic, contacts/);
  assert.match(sql, /'twist:' \|\| v_plot_twist_id::text/);
  // topic_id (the FK that files topic members) AND the topic text are both set.
  assert.match(sql, /v_updates_topic_id, 'topic:' \|\| v_updates_topic_id::text/);
  assert.match(sql, /ARRAY\[c_system_instance_id\]/);
  assert.doesNotMatch(sql, /\bgroups\b/); // global onboarding threads carry no groups
});

test("escapes single quotes in content and title", () => {
  const sql = emitGlobalReconcile(
    model([thread({ title: "It's here", notes: [{ key: "intro", content: "a ' b" }] })]),
    { archivedThreadKeys: [], archivedNoteKeys: [] },
  );
  assert.match(sql, /It''s here/);
  assert.match(sql, /a '' b/);
});

test("upserts thread by key (scoped to system author) and note by (thread_id, key)", () => {
  const sql = emitGlobalReconcile(model([thread({})]), { archivedThreadKeys: [], archivedNoteKeys: [] });
  assert.match(sql, /WHERE key = 'welcome' AND created_by = c_system_instance_id/);
  // notes upsert manually by (thread_id, key) with link_id IS NULL (NULLS-distinct
  // unique index can't be used as an ON CONFLICT arbiter for NULL link_id).
  assert.match(sql, /WHERE thread_id = v_thread_id AND key = 'intro' AND link_id IS NULL/);
  assert.doesNotMatch(sql, /ON CONFLICT/);
});

test("archives removed keys with archived_at, never DELETE", () => {
  const sql = emitGlobalReconcile(model([thread({})]), {
    archivedThreadKeys: ["clean-up"],
    archivedNoteKeys: ["welcome/old-note"],
  });
  assert.match(sql, /UPDATE public\.thread\s+SET archived_at = now\(\)\s+WHERE key = 'clean-up' AND created_by = c_system_instance_id/);
  assert.match(sql, /UPDATE public\.note n SET archived_at = now\(\)/);
  assert.doesNotMatch(sql, /DELETE FROM/i);
});
