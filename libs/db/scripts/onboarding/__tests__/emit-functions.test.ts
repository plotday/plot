import { test } from "node:test";
import assert from "node:assert/strict";
import { emitSchedulesRegion, emitTodosRegion, emitWelcomeUserRegion, replaceRegion } from "../emit-functions.ts";
import type { ThreadDef } from "../model.ts";

const t = (key: string, order: number, active: boolean, importance: number | null, dateOffset: number | null, hasTodo: boolean): ThreadDef => ({
  key,
  order,
  title: key,
  preview: "p",
  state: { active, importance, dateOffset },
  notes: hasTodo ? [{ key: "intro", content: "i" }, { key: "todo", content: "do" }] : [{ key: "intro", content: "i" }],
});

test("schedules region emits a CASE arm per thread", () => {
  const region = emitSchedulesRegion([
    t("welcome", 1, false, 95, 0, false),
    t("twists", 5, true, 70, 1, true),
  ]);
  assert.match(region, /WHEN 'welcome'\s+THEN/);
  assert.match(region, /v_active := FALSE/);
  assert.match(region, /WHEN 'twists'\s+THEN/);
  assert.match(region, /v_active := TRUE/);
  assert.match(region, /v_date_offset := 1/);
  assert.match(region, /IN \('welcome', 'twists'\)/);
});

test("todos region lists only threads with a todo note", () => {
  const region = emitTodosRegion([
    t("welcome", 1, false, 95, 0, false),
    t("twists", 5, true, 70, 1, true),
  ]);
  assert.match(region, /IN \('twists'\)/);
});

test("todos region with no todo notes emits a valid no-op, never IN ()", () => {
  const region = emitTodosRegion([
    t("welcome", 1, false, 95, 0, false),
    t("getting-around", 4, false, 80, 0, false),
  ]);
  assert.doesNotMatch(region, /IN \(\)/, "empty IN () is invalid SQL");
  assert.match(region, /RETURN NEW;/);
});

test("schedules region with no threads emits a valid no-op, never IN ()", () => {
  const region = emitSchedulesRegion([]);
  assert.doesNotMatch(region, /IN \(\)/, "empty IN () is invalid SQL");
  assert.match(region, /RETURN NEW;/);
});

test("welcome-user region contains key, both note keys, importance", () => {
  const region = emitWelcomeUserRegion(
    t("welcome-user", 1, false, 100, null, false),
  );
  assert.match(region, /'welcome-user'/);
  assert.match(region, /100/);
});

test("welcome-user region emits each note", () => {
  const region = emitWelcomeUserRegion({
    key: "welcome-user", order: 1, title: "Welcome to Plot!", preview: "Glad.",
    state: { active: false, importance: 100, dateOffset: null },
    notes: [{ key: "welcome", content: "hi" }, { key: "core-trial", content: "trial" }],
  });
  assert.match(region, /'welcome'/);
  assert.match(region, /'core-trial'/);
});

test("replaceRegion swaps content between markers, idempotently", () => {
  const file = "a\n-- ONBOARDING:BEGIN x\nOLD\n-- ONBOARDING:END x\nb\n";
  const out = replaceRegion(file, "x", "NEW");
  assert.equal(out, "a\n-- ONBOARDING:BEGIN x\nNEW\n-- ONBOARDING:END x\nb\n");
  assert.equal(replaceRegion(out, "x", "NEW"), out);
});
