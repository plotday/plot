import { describe, expect, it } from "vitest";

import { computeLcaPath } from "./notification-content";

describe("computeLcaPath", () => {
  it('returns single path unchanged', () => {
    expect(computeLcaPath(["abc.work.project"], "abc.work")).toBe("abc.work.project");
  });

  it('returns shared prefix for two paths', () => {
    expect(computeLcaPath(["abc.work.frontend", "abc.work.backend"], "abc.work")).toBe("abc.work");
  });

  it('returns fallback when no shared segments', () => {
    expect(computeLcaPath(["abc.work", "xyz.personal"], "fallback")).toBe("fallback");
  });

  it('returns first-level LCA for 3 paths where LCA is at first level', () => {
    expect(computeLcaPath([
      "abc.work.frontend.ui",
      "abc.work.backend.api",
      "abc.work.devops",
    ], "abc.work")).toBe("abc.work");
  });

  it('returns empty array fallback', () => {
    expect(computeLcaPath([], "fallback")).toBe("fallback");
  });

  it('computes partial shared prefix correctly', () => {
    expect(computeLcaPath([
      "root.a.b.c",
      "root.a.b.d",
    ], "root.a")).toBe("root.a.b");
  });

  it('returns single-segment path when all paths share it', () => {
    expect(computeLcaPath(["myroot", "myroot"], "fallback")).toBe("myroot");
  });

  it('returns root when paths have mixed depths', () => {
    expect(computeLcaPath(["root.child", "root"], "fallback")).toBe("root");
  });
});
