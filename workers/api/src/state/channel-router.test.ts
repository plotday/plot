import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type * as dbModule from "../db";
import { TRANSIENT_ALARM_RETRY_DELAYS_MS } from "./alarm-retry";
import { ChannelRouter } from "./channel-router";

const {
  captureExceptionSpy,
  captureSpy,
  withDbMock,
  withUserDbMock,
  generateObjectMock,
  notifyUserSyncMock,
  sqlResponses,
} = vi.hoisted(() => ({
  captureExceptionSpy: vi.fn(),
  captureSpy: vi.fn(),
  withDbMock: vi.fn(),
  withUserDbMock: vi.fn(),
  generateObjectMock: vi.fn(),
  notifyUserSyncMock: vi.fn(),
  // Queue of canned rows handed out, in order, to each `sql\`...\`.execute()`
  // call made inside runRouter's data-fetch transaction (priorities, then
  // channels, then thread-title samples).
  sqlResponses: [] as unknown[],
}));

vi.mock("posthog-node", () => ({
  PostHog: class {
    captureException = captureExceptionSpy;
    capture = captureSpy;
    async shutdown() {}
  },
}));

vi.mock("../db", async (importOriginal) => ({
  ...(await importOriginal<typeof dbModule>()),
  withDb: withDbMock,
  withUserDb: withUserDbMock,
}));

// Capture the generateObject params so we can assert on the ai@7 instructions
// shape (see generator.test.ts for the reference pattern).
vi.mock("ai", () => ({
  generateObject: (...args: unknown[]) => generateObjectMock(...args),
}));

vi.mock("../utils/ai-limits", () => ({
  isAiEnabled: () => Promise.resolve(true),
}));

vi.mock("../app/sync/notify", () => ({
  notifyUserSyncByEnv: (...args: unknown[]) => notifyUserSyncMock(...args),
}));

// Only `sql` is overridden; everything else (types, other runtime exports)
// passes through untouched. `withDb`/`withUserDb` are fully replaced above,
// so the only real call sites left touching `sql` are channel-router.ts's
// own three tagged-template queries in the data-fetch transaction.
vi.mock("kysely", async (importOriginal) => ({
  ...(await importOriginal<typeof import("kysely")>()),
  sql: (..._args: unknown[]) => ({
    execute: async () => sqlResponses.shift() ?? { rows: [] },
  }),
}));

describe("ChannelRouter alarm failure handling", () => {
  const NOW = 1_750_000_000_000;
  const USER_ID = "019d91c2-4d0d-798e-b920-4340faf6b2ff";

  let storageMap: Map<string, unknown>;
  let setAlarm: ReturnType<typeof vi.fn>;
  let router: ChannelRouter;

  beforeEach(async () => {
    vi.spyOn(Date, "now").mockReturnValue(NOW);
    captureExceptionSpy.mockClear();
    captureSpy.mockClear();
    withDbMock.mockReset();

    storageMap = new Map<string, unknown>([["userId", USER_ID]]);
    setAlarm = vi.fn();

    let ready: Promise<void> = Promise.resolve();
    const ctx = {
      storage: {
        get: vi.fn(async (key: string) => storageMap.get(key)),
        put: vi.fn(async (key: string, value: unknown) => {
          storageMap.set(key, value);
        }),
        setAlarm,
      },
      waitUntil: vi.fn(),
      blockConcurrencyWhile: vi.fn((fn: () => Promise<void>) => {
        ready = fn();
      }),
    };
    const env = { POSTHOG_API_KEY: "key", POSTHOG_HOST: "host" };
    router = new ChannelRouter(
      ctx as unknown as DurableObjectState,
      env as never
    );
    await ready;
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("reschedules without capturing on a transient failure", async () => {
    withDbMock.mockRejectedValue(
      new Error("Connection terminated unexpectedly")
    );

    await router.alarm();

    expect(setAlarm).toHaveBeenCalledWith(
      NOW + TRANSIENT_ALARM_RETRY_DELAYS_MS[0]
    );
    expect(captureExceptionSpy).not.toHaveBeenCalled();
  });

  it("captures once the transient retry budget is exhausted", async () => {
    withDbMock.mockRejectedValue(
      new Error("Timed out while waiting for an open slot in the pool.")
    );

    for (let i = 0; i < TRANSIENT_ALARM_RETRY_DELAYS_MS.length; i++) {
      await router.alarm();
    }
    expect(captureExceptionSpy).not.toHaveBeenCalled();

    await router.alarm();

    expect(captureExceptionSpy).toHaveBeenCalledTimes(1);
  });

  it("captures immediately on an unexpected failure without rescheduling", async () => {
    withDbMock.mockRejectedValue(new Error("boom"));

    await router.alarm();

    expect(captureExceptionSpy).toHaveBeenCalledTimes(1);
    expect(setAlarm).not.toHaveBeenCalled();
  });
});

describe("ChannelRouter LLM call shape", () => {
  const USER_ID = "019d91c2-4d0d-798e-b920-4340faf6b2ff";

  beforeEach(async () => {
    captureExceptionSpy.mockClear();
    withDbMock.mockReset();
    withUserDbMock.mockReset();
    generateObjectMock.mockReset();
    notifyUserSyncMock.mockReset();
    sqlResponses.length = 0;

    // Fake db object: `withDb`/`withUserDb` are fully mocked (see top of
    // file), so this never needs to satisfy the real Kysely interface — it
    // only flows through as an opaque handle to the mocked `sql.execute()`.
    const fakeDb = {};
    withDbMock.mockImplementation(
      async (_env: unknown, cb: (db: unknown) => Promise<void>) => cb(fakeDb)
    );
    withUserDbMock.mockImplementation(
      async (
        db: unknown,
        _userId: string,
        cb: (trx: unknown) => Promise<unknown>
      ) => cb(db)
    );
    notifyUserSyncMock.mockResolvedValue(undefined);

    // Data-fetch transaction issues three queries in order: priorities,
    // channels, then thread-title samples (samples only run when the
    // channels query returned rows, which it does here).
    sqlResponses.push(
      { rows: [{ id: "019d0000-0000-7000-8000-000000000001", path: "Work", title: "Work", description: null }] },
      { rows: [{ pk: 1, connector: "gmail", connector_description: "Email", account_label: "kris@acme.com", title: "Inbox", link_types: {}, current_default_priority_id: null }] },
      { rows: [] }
    );
    // Empty results keeps the post-LLM per-channel commit loop a no-op, so
    // the test only needs to satisfy the data-fetch queries above.
    generateObjectMock.mockResolvedValue({ object: { results: [] } });
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  async function createRouter(): Promise<ChannelRouter> {
    const storageMap = new Map<string, unknown>([["userId", USER_ID]]);
    let ready: Promise<void> = Promise.resolve();
    const ctx = {
      storage: {
        get: vi.fn(async (key: string) => storageMap.get(key)),
        put: vi.fn(async (key: string, value: unknown) => {
          storageMap.set(key, value);
        }),
        setAlarm: vi.fn(),
      },
      waitUntil: vi.fn(),
      blockConcurrencyWhile: vi.fn((fn: () => Promise<void>) => {
        ready = fn();
      }),
    };
    const env = {
      POSTHOG_API_KEY: "key",
      POSTHOG_HOST: "host",
      AI_GATEWAY_ACCOUNT_ID: "acct",
      AI_GATEWAY_ID: "gw",
      AI_GATEWAY_TOKEN: "token",
      GOOGLE_GENERATIVE_AI_API_KEY: "gkey",
    };
    const router = new ChannelRouter(
      ctx as unknown as DurableObjectState,
      env as never
    );
    await ready;
    return router;
  }

  it("sends the system prompt via `instructions` and only a user message in `messages`", async () => {
    const router = await createRouter();

    await router.alarm();

    expect(generateObjectMock).toHaveBeenCalledTimes(1);
    const call = generateObjectMock.mock.calls[0][0];
    // Gemini (the system model) needs no provider-specific caching options,
    // so instructions is a plain string — a `{role:"system"}` messages entry
    // here would make ai@7's generateObject throw before any network call.
    expect(typeof call.instructions).toBe("string");
    expect(call.instructions).toContain("assign a default Plot priority");
    expect(call.messages).toHaveLength(1);
    expect(call.messages[0].role).toBe("user");

    expect(captureExceptionSpy).not.toHaveBeenCalled();
  });
});
