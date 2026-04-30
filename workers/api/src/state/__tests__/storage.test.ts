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
