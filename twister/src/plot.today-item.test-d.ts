import { describe, expectTypeOf, it } from "vitest";
import type { Note, NewNote } from "./plot";

describe("Note.todayItem", () => {
  it("is a required { id } | null field on Note", () => {
    expectTypeOf<Note["todayItem"]>().toEqualTypeOf<{ id: Note["id"] } | null>();
  });
  it("is NOT settable on NewNote", () => {
    expectTypeOf<NewNote>().not.toHaveProperty("todayItem");
  });
});
