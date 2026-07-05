import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";

import type { Storage } from "../storage";

declare module "cloudflare:test" {
  interface ProvidedEnv {
    STORAGE: DurableObjectNamespace<Storage>;
  }
}

function getStorage(name: string): DurableObjectStub<Storage> {
  return env.STORAGE.get(env.STORAGE.idFromName(name));
}

describe("Storage.list", () => {
  let stub: DurableObjectStub<Storage>;

  beforeEach(async () => {
    stub = getStorage(`test-${crypto.randomUUID()}`);
    await stub.clearAll();
  });

  it("returns all non-lock keys when prefix is empty", async () => {
    await stub.set("a:1", "v");
    await stub.set("b:2", "v");
    await stub.acquireLock("hidden", 60_000);

    const keys = await stub.list("");

    expect(keys.sort()).toEqual(["a:1", "b:2"]);
  });

  it("returns only keys matching the prefix", async () => {
    await stub.set("foo:1", "v");
    await stub.set("foo:2", "v");
    await stub.set("bar:1", "v");

    const keys = await stub.list("foo:");

    expect(keys.sort()).toEqual(["foo:1", "foo:2"]);
  });

  it("matches the prefix literally — % is not a wildcard", async () => {
    await stub.set("a%b:1", "v");
    await stub.set("axb:1", "v");

    const keys = await stub.list("a%b:");

    expect(keys).toEqual(["a%b:1"]);
  });

  it("matches the prefix literally — _ is not a wildcard", async () => {
    await stub.set("a_b:1", "v");
    await stub.set("axb:1", "v");

    const keys = await stub.list("a_b:");

    expect(keys).toEqual(["a_b:1"]);
  });

  it("handles a prefix longer than the LIKE pattern limit (50 bytes)", async () => {
    // Regression test: Cloudflare DO SQLite caps LIKE patterns at 50 bytes,
    // so a `key LIKE '<long-prefix>%'` query throws
    // "LIKE or GLOB pattern too complex". Range-scan based list() must
    // handle long prefixes (real-world example: Outlook iCalUIDs are 100+
    // chars, making `pending_occ:google-calendar:<iCalUID>:` exceed 50).
    const longSource =
      "google-calendar:040000008200E00074C5B7101A82E0080000000010F8B7CCD27BD901@google.com";
    const longPrefix = `pending_occ:${longSource}:`;
    expect(longPrefix.length).toBeGreaterThan(50);

    await stub.set(`${longPrefix}1`, "v");
    await stub.set(`${longPrefix}2`, "v");
    await stub.set("other:1", "v");

    const keys = await stub.list(longPrefix);

    expect(keys.sort()).toEqual([`${longPrefix}1`, `${longPrefix}2`]);
  });

  it("excludes lock keys from results", async () => {
    await stub.set("foo:1", "v");
    await stub.acquireLock("foo:lock", 60_000);

    const all = await stub.list("");
    expect(all).toEqual(["foo:1"]);

    const fooKeys = await stub.list("foo:");
    expect(fooKeys).toEqual(["foo:1"]);
  });
});

describe("Storage.list — reserved __drain__ namespace", () => {
  let stub: DurableObjectStub<Storage>;

  beforeEach(async () => {
    stub = getStorage(`test-${crypto.randomUUID()}`);
    await stub.clearAll();
  });

  it("hides __drain__ keys from general listings", async () => {
    await stub.set("foo:1", "v");
    await stub.set("__drain__:sync:a", "0");

    expect(await stub.list("")).toEqual(["foo:1"]);
    expect(await stub.list("foo:")).toEqual(["foo:1"]);
  });

  it("returns __drain__ keys when the prefix opts into the namespace", async () => {
    await stub.set("__drain__:sync:a", "0");
    await stub.set("__drain__:sync:b", "1");
    await stub.set("__drain__:other:c", "0");

    const keys = await stub.list("__drain__:sync:");
    expect(keys.sort()).toEqual(["__drain__:sync:a", "__drain__:sync:b"]);
  });
});

describe("Storage.setMany", () => {
  let stub: DurableObjectStub<Storage>;

  beforeEach(async () => {
    stub = getStorage(`test-${crypto.randomUUID()}`);
    await stub.clearAll();
  });

  it("writes all entries in one call", async () => {
    await stub.setMany([
      ["a:1", "v1"],
      ["a:2", "v2"],
      ["b:1", "v3"],
    ]);

    expect(await stub.get("a:1")).toBe("v1");
    expect(await stub.get("a:2")).toBe("v2");
    expect(await stub.get("b:1")).toBe("v3");
  });

  it("upserts existing keys", async () => {
    await stub.set("a:1", "old");

    await stub.setMany([
      ["a:1", "new"],
      ["a:2", "v2"],
    ]);

    expect(await stub.get("a:1")).toBe("new");
    expect(await stub.get("a:2")).toBe("v2");
  });

  it("is a no-op for an empty batch", async () => {
    await stub.setMany([]);
    expect(await stub.list("")).toEqual([]);
  });
});
