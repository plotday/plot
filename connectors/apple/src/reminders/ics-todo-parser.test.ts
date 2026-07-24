import { describe, expect, it } from "vitest";

import { parseICSTodos } from "./ics-todo-parser";

function wrapVCalendar(vtodo: string): string {
  return `BEGIN:VCALENDAR\r\nVERSION:2.0\r\n${vtodo}\r\nEND:VCALENDAR`;
}

describe("parseICSTodos", () => {
  it("parses a basic open reminder with a DUE date", () => {
    const ics = wrapVCalendar(
      [
        "BEGIN:VTODO",
        "UID:abc-123",
        "SUMMARY:Buy milk",
        "DESCRIPTION:2%",
        "DUE;VALUE=DATE:20260901",
        "STATUS:NEEDS-ACTION",
        "SEQUENCE:0",
        "CREATED:20260824T120000Z",
        "END:VTODO",
      ].join("\r\n")
    );

    const todos = parseICSTodos(ics);
    expect(todos).toHaveLength(1);
    expect(todos[0]).toMatchObject({
      uid: "abc-123",
      summary: "Buy milk",
      description: "2%",
      due: { value: "20260901", params: { VALUE: "DATE" } },
      status: "NEEDS-ACTION",
      sequence: 0,
      created: "20260824T120000Z",
    });
  });

  it("parses a completed reminder with COMPLETED timestamp", () => {
    const ics = wrapVCalendar(
      [
        "BEGIN:VTODO",
        "UID:done-1",
        "SUMMARY:Renew passport",
        "STATUS:COMPLETED",
        "COMPLETED:20260810T090000Z",
        "END:VTODO",
      ].join("\r\n")
    );

    const [todo] = parseICSTodos(ics);
    expect(todo.status).toBe("COMPLETED");
    expect(todo.completed).toEqual({ value: "20260810T090000Z", params: {} });
  });

  it("parses a cancelled reminder", () => {
    const ics = wrapVCalendar(
      ["BEGIN:VTODO", "UID:cancelled-1", "SUMMARY:Old task", "STATUS:CANCELLED", "END:VTODO"].join(
        "\r\n"
      )
    );
    expect(parseICSTodos(ics)[0].status).toBe("CANCELLED");
  });

  it("parses a recurring reminder's RRULE without expanding it", () => {
    const ics = wrapVCalendar(
      [
        "BEGIN:VTODO",
        "UID:recurring-1",
        "SUMMARY:Take out trash",
        "DUE;VALUE=DATE:20260901",
        "RRULE:FREQ=WEEKLY;BYDAY=TU",
        "END:VTODO",
      ].join("\r\n")
    );
    expect(parseICSTodos(ics)[0].rrule).toBe("FREQ=WEEKLY;BYDAY=TU");
  });

  it("parses RELATED-TO for a subtask", () => {
    const ics = wrapVCalendar(
      [
        "BEGIN:VTODO",
        "UID:child-1",
        "SUMMARY:Pack shoes",
        "RELATED-TO:parent-1",
        "END:VTODO",
      ].join("\r\n")
    );
    expect(parseICSTodos(ics)[0].relatedTo).toBe("parent-1");
  });

  it("returns null relatedTo/due/completed when absent, and defaults sequence to 0", () => {
    const ics = wrapVCalendar(["BEGIN:VTODO", "UID:bare-1", "SUMMARY:No due date", "END:VTODO"].join("\r\n"));
    const [todo] = parseICSTodos(ics);
    expect(todo.due).toBeNull();
    expect(todo.completed).toBeNull();
    expect(todo.relatedTo).toBeNull();
    expect(todo.status).toBeNull();
    expect(todo.sequence).toBe(0);
  });

  it("parses multiple VTODO blocks in one VCALENDAR", () => {
    const ics = `BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VTODO\r\nUID:one\r\nSUMMARY:First\r\nEND:VTODO\r\nBEGIN:VTODO\r\nUID:two\r\nSUMMARY:Second\r\nEND:VTODO\r\nEND:VCALENDAR`;
    expect(parseICSTodos(ics).map((t) => t.uid)).toEqual(["one", "two"]);
  });

  it("skips a VTODO block with no UID", () => {
    const ics = wrapVCalendar(["BEGIN:VTODO", "SUMMARY:Missing UID", "END:VTODO"].join("\r\n"));
    expect(parseICSTodos(ics)).toEqual([]);
  });
});
