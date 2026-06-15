import { describe, it, expect } from "vitest";

import { mapTaskStatus } from "./todoist";

describe("mapTaskStatus", () => {
  it("returns 'done' for completed tasks regardless of section", () => {
    expect(mapTaskStatus({ is_completed: true, section_id: "123" } as any)).toBe("done");
  });

  it("returns 'done' for a completed task with no section", () => {
    expect(mapTaskStatus({ is_completed: true, section_id: null } as any)).toBe("done");
  });

  it("returns the section id for an open task in a section", () => {
    expect(mapTaskStatus({ is_completed: false, section_id: "123" } as any)).toBe("123");
  });

  it("returns 'open' for an open task with no section", () => {
    expect(mapTaskStatus({ is_completed: false, section_id: null } as any)).toBe("open");
  });

  it("returns 'open' for an open task with undefined section", () => {
    expect(mapTaskStatus({ is_completed: false } as any)).toBe("open");
  });
});
