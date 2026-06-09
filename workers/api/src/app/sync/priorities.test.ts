import { describe, expect, it } from "vitest";

import { projectPriority } from "./priorities";

describe("projectPriority", () => {
  it("uses the raw leaf title for a flat client, never an ancestry breadcrumb", () => {
    // Regression: the old projection substituted flat_title ("Plot › Marketing")
    // into `title`. The client round-tripped that back into priority.title,
    // making renames appear to revert. `title` must stay the user-editable leaf.
    const row = {
      id: "p1",
      root: false,
      title: "Marketing",
      flat_title: "Plot › Movement Building › Marketing",
    };
    const out = projectPriority(row, 4);
    expect(out.title).toBe("Marketing");
    expect("flat_title" in out).toBe(false);
  });

  it("labels the per-user root 'Inbox' for a flat client", () => {
    const out = projectPriority({ id: "r", root: true, title: "Everything" }, 4);
    expect(out.title).toBe("Inbox");
  });

  it("leaves the row otherwise unchanged for a flat client", () => {
    const out = projectPriority(
      { id: "p1", root: false, title: "Marketing", color: 3, icon: "bullhorn" },
      4,
    );
    expect(out).toMatchObject({ id: "p1", title: "Marketing", color: 3, icon: "bullhorn" });
  });

  it("passes the row through (minus flat_title) for pre-flat clients", () => {
    const row = { id: "p1", root: false, title: "Marketing", flat_title: "x" };
    const out = projectPriority(row, 3);
    expect(out.title).toBe("Marketing");
    expect("flat_title" in out).toBe(false);
  });
});
