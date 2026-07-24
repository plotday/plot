import { describe, expect, it } from "vitest";

import { remindersSource, transformTodo } from "./transform";
import type { ICSTodo } from "./ics-todo-parser";

function makeTodo(overrides: Partial<ICSTodo> = {}): ICSTodo {
  return {
    uid: "abc-123",
    summary: "Buy milk",
    description: null,
    due: null,
    completed: null,
    status: null,
    priority: null,
    relatedTo: null,
    rrule: null,
    sequence: 0,
    created: null,
    lastModified: null,
    url: null,
    ...overrides,
  };
}

const ACTOR_ID = "actor-1" as unknown as import("@plotday/twister").ActorId;

describe("remindersSource", () => {
  it("is globally unique per UID", () => {
    expect(remindersSource("abc-123")).toBe("icloud-reminders:reminder:abc-123");
  });
});

describe("transformTodo", () => {
  it("maps an open reminder with a DUE date to an open todo", () => {
    const todo = makeTodo({ due: { value: "20260901", params: { VALUE: "DATE" } } });
    const link = transformTodo(todo, "/tasks/home/abc-123.ics", "/tasks/home/", false, [], ACTOR_ID);

    expect(link).toMatchObject({
      source: "icloud-reminders:reminder:abc-123",
      type: "reminder",
      title: "Buy milk",
      status: "open",
      channelId: "/tasks/home/",
      todo: true,
      todoDate: "2026-09-01",
      author: { id: ACTOR_ID },
      assignee: { id: ACTOR_ID },
    });
  });

  it("maps a COMPLETED reminder to done, with no todo/todoDate", () => {
    const todo = makeTodo({ status: "COMPLETED" });
    const link = transformTodo(todo, "/tasks/home/abc-123.ics", "/tasks/home/", false, [], ACTOR_ID);

    expect(link?.status).toBe("done");
    expect(link).not.toHaveProperty("todo");
    expect(link).not.toHaveProperty("todoDate");
  });

  it("returns null for a CANCELLED reminder (callers archive instead of upserting)", () => {
    const todo = makeTodo({ status: "CANCELLED" });
    expect(
      transformTodo(todo, "/tasks/home/abc-123.ics", "/tasks/home/", false, [], ACTOR_ID)
    ).toBeNull();
  });

  it("sets unread:false and archived:false only on initial sync", () => {
    const todo = makeTodo();
    const initial = transformTodo(todo, "/tasks/home/abc-123.ics", "/tasks/home/", true, [], ACTOR_ID);
    const incremental = transformTodo(
      todo,
      "/tasks/home/abc-123.ics",
      "/tasks/home/",
      false,
      [],
      ACTOR_ID
    );

    expect(initial).toMatchObject({ unread: false, archived: false });
    expect(incremental).not.toHaveProperty("unread");
    expect(incremental).not.toHaveProperty("archived");
  });

  it("attaches a description note authored by the connection owner", () => {
    const todo = makeTodo({ description: "2% milk" });
    const link = transformTodo(todo, "/tasks/home/abc-123.ics", "/tasks/home/", false, [], ACTOR_ID);

    expect(link?.notes).toEqual([
      { key: "description", content: "2% milk", contentType: "text", author: { id: ACTOR_ID } },
    ]);
  });

  it("renders subtasks as Todo/Done-tagged notes on the parent thread", () => {
    const parent = makeTodo();
    const openSub = makeTodo({ uid: "sub-1", summary: "Pack shoes", relatedTo: "abc-123" });
    const doneSub = makeTodo({
      uid: "sub-2",
      summary: "Buy socks",
      relatedTo: "abc-123",
      status: "COMPLETED",
    });

    const link = transformTodo(
      parent,
      "/tasks/home/abc-123.ics",
      "/tasks/home/",
      false,
      [openSub, doneSub],
      ACTOR_ID
    );

    expect(link?.notes).toEqual([
      {
        key: "subtask-sub-1",
        content: "Pack shoes",
        tags: { add: [{ id: ACTOR_ID }] },
        twistTags: { 1: true },
      },
      { key: "subtask-sub-2", content: "Buy socks", tags: { add: [3] } },
    ]);
  });

  it("stores todoUid/todoHref/listId/syncProvider in meta for write-back lookup", () => {
    const link = transformTodo(
      makeTodo(),
      "/tasks/home/abc-123.ics",
      "/tasks/home/",
      false,
      [],
      ACTOR_ID
    );
    expect(link?.meta).toEqual({
      todoUid: "abc-123",
      todoHref: "/tasks/home/abc-123.ics",
      listId: "/tasks/home/",
      syncProvider: "apple-reminders",
      channelId: "/tasks/home/",
    });
  });

  it("omits todoDate when there is no DUE date", () => {
    const link = transformTodo(
      makeTodo({ due: null }),
      "/tasks/home/abc-123.ics",
      "/tasks/home/",
      false,
      [],
      ACTOR_ID
    );
    expect(link?.todo).toBe(true);
    expect(link).not.toHaveProperty("todoDate");
  });
});
