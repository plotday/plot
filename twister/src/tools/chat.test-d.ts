import { expectTypeOf, test } from "vitest";

import { type Action, ActionType, type Uuid } from "../plot";
import type { ChatSession, ChatSpec, NewChatSpec } from "./chat";

test("chat action is part of the Action union and carries a fallback url", () => {
  const action: Action = {
    type: ActionType.chat,
    title: "Talk it through",
    url: "https://app.plot.day/t/abc",
    callback: "token" as never,
  };
  expectTypeOf(action).toMatchTypeOf<Action>();
});

test("ChatSpec fields are nullable, never optional", () => {
  expectTypeOf<ChatSpec["greeting"]>().toEqualTypeOf<string | null>();
  expectTypeOf<ChatSpec["voice"]>().toEqualTypeOf<string | null>();
  expectTypeOf<ChatSpec["historyLimit"]>().toEqualTypeOf<number | null>();
  expectTypeOf<ChatSpec["maxSeconds"]>().toEqualTypeOf<number | null>();
});

test("NewChatSpec requires only instructions and onEnded", () => {
  expectTypeOf<{
    instructions: string;
    onEnded: ChatSpec["onEnded"];
  }>().toMatchTypeOf<NewChatSpec>();
});

test("ChatSession turns carry role, content and the note they became", () => {
  expectTypeOf<ChatSession["turns"][number]["role"]>().toEqualTypeOf<
    "user" | "agent"
  >();
  expectTypeOf<ChatSession["turns"][number]["noteId"]>().toEqualTypeOf<Uuid>();
  expectTypeOf<ChatSession["endedBy"]>().toEqualTypeOf<
    "user" | "cap" | "error" | "disconnect"
  >();
});
