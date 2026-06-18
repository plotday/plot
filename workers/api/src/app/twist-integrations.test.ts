import { beforeEach, describe, expect, it, vi } from "vitest";
import { Hono } from "hono";
import twistIntegrations from "./twist-integrations";
import { Integrations } from "../twist/tools/integrations";
import { UnipileApiError } from "../twist/tools/unipile/client";

/**
 * Tests for POST /twist/:id/integrations/auth — specifically that upstream
 * auth-URL generation failures (e.g. a hosted-auth provider's backend like
 * Unipile returning 401, or the provider being down) are translated into a
 * clean 502 instead of bubbling to the global handler as an opaque
 * `500 Internal Server Error`.
 *
 * Dependencies are satisfied with fakes (mirroring files-ref.test.ts):
 *   - `db`: a chainable Kysely-like builder whose executeTakeFirst() returns a
 *     row that satisfies both checkTwistAccess (owner_id/team_id) and
 *     resolveTwistInfo (twistPackageId/version/...).
 *   - `env.TWIST_CONFIG`: KV stub returning a provider config.
 *   - `env.CALLBACKS`: durable-object stub whose create() returns a token.
 *   - `Integrations.GenerateAuthUrl`: spied per-test.
 */

const TEST_USER_ID = "user-uuid-001";
const TEST_TWIST_INSTANCE_ID = "ti-uuid-001";

// One row that satisfies both checkTwistAccess (owner match → { ok: true })
// and resolveTwistInfo (twistPackageId + version drive loadTwistConfig).
const TWIST_ROW = {
  owner_id: TEST_USER_ID,
  team_id: null,
  twistId: "twist-pkg-uuid",
  accountLabel: null,
  teamId: null,
  teamName: null,
  version: "1.0.0",
  environment: "production",
  twistOptions: null,
  shared: false,
  keyOption: null,
  premium: false,
  twistPackageId: "linkedin",
};

function makeDb(row: unknown) {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const q: any = {};
  q.selectFrom = vi.fn(() => q);
  q.innerJoin = vi.fn(() => q);
  q.leftJoin = vi.fn(() => q);
  q.select = vi.fn(() => q);
  q.where = vi.fn(() => q);
  q.executeTakeFirst = vi.fn(async () => row);
  return q;
}

const KV_CONFIG = JSON.stringify({
  providers: [{ provider: "linkedin", scopes: ["messaging"] }],
  integrationsMap: { linkedin: "ConnectorClass:integrations" },
});

function makeEnv() {
  return {
    TWIST_CONFIG: { get: vi.fn(async () => KV_CONFIG) },
    CALLBACKS: {
      idFromName: vi.fn(() => "callbacks-do-id"),
      get: vi.fn(() => ({ create: vi.fn(async () => "callback-token") })),
    },
    STORAGE: {},
    API_ROOT: "https://api.test",
  };
}

const captureExceptionMock = vi.fn();

async function postAuth(
  body: unknown,
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  opts?: { env?: any; db?: any; user?: { id: string } | null },
) {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const app = new Hono<{ Bindings: any }>();
  app.use("*", async (c, next) => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (c as any).set("user", opts?.user ?? { id: TEST_USER_ID });
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (c as any).set("db", opts?.db ?? makeDb(TWIST_ROW));
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (c as any).set("tracker", { captureException: captureExceptionMock });
    await next();
  });
  app.route("/", twistIntegrations);

  const req = new Request(
    `http://localhost/twist/${TEST_TWIST_INSTANCE_ID}/integrations/auth`,
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    },
  );
  return app.fetch(req, opts?.env ?? makeEnv(), {
    waitUntil: () => {},
    passThroughOnException: () => {},
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any);
}

describe("POST /twist/:id/integrations/auth", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    vi.clearAllMocks();
  });

  it("returns 502 and captures when GenerateAuthUrl throws (e.g. Unipile 401)", async () => {
    vi.spyOn(Integrations, "GenerateAuthUrl").mockRejectedValue(
      new UnipileApiError(
        "Unipile POST /hosted/accounts/link returned 401",
        401,
        "",
      ),
    );

    const res = await postAuth({
      provider: "linkedin",
      redirectUri: "plotday://auth",
    });

    expect(res.status).toBe(502);
    const json = (await res.json()) as { message: string };
    expect(json.message).toMatch(/unavailable/i);
    expect(captureExceptionMock).toHaveBeenCalledWith(
      expect.any(Error),
      expect.objectContaining({ context: "integrations:auth" }),
    );
  });

  it("returns 200 with the auth URL and callback on success", async () => {
    vi.spyOn(Integrations, "GenerateAuthUrl").mockResolvedValue({
      url: "https://provider.test/oauth",
      clientId: "hosted",
      state: "state-token",
    });

    const res = await postAuth({
      provider: "linkedin",
      redirectUri: "plotday://auth",
    });

    expect(res.status).toBe(200);
    const json = (await res.json()) as {
      url: string;
      callback: string;
    };
    expect(json.url).toBe("https://provider.test/oauth");
    expect(json.callback).toBe("callback-token");
    expect(captureExceptionMock).not.toHaveBeenCalled();
  });
});
