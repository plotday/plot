import { describe, it, expect } from "vitest";
import { partitionOrphanHostedAccounts } from "./integrations";

// getIntegrationData lists a connection's accounts by scanning
// `auth_token:{provider}:{actorId}` DO keys. A hosted-auth connection
// (LinkedIn / WhatsApp / Instagram) is bound to exactly ONE upstream account
// recorded in `twist_instance_connection.actor_id`, but a reconnect that
// re-binds the same upstream account to a corrected owner contact leaves the
// previous actor's token behind — so the DO ends up with two auth_token keys
// and the modal shows the account twice. This helper drops the orphan.
describe("partitionOrphanHostedAccounts", () => {
  const hosted = new Set(["linkedin"]);

  it("drops a hosted account whose actor is not the canonical binding", () => {
    const accounts = [
      { provider: "linkedin", actorId: "actor-bound" },
      { provider: "linkedin", actorId: "actor-orphan" },
    ];
    const { kept, orphans } = partitionOrphanHostedAccounts(
      accounts,
      hosted,
      new Set(["actor-bound"]),
    );
    expect(kept).toEqual([{ provider: "linkedin", actorId: "actor-bound" }]);
    expect(orphans).toEqual([{ provider: "linkedin", actorId: "actor-orphan" }]);
  });

  it("keeps a single canonical hosted account untouched", () => {
    const accounts = [{ provider: "linkedin", actorId: "actor-bound" }];
    const { kept, orphans } = partitionOrphanHostedAccounts(
      accounts,
      hosted,
      new Set(["actor-bound"]),
    );
    expect(kept).toEqual(accounts);
    expect(orphans).toEqual([]);
  });

  it("fail-safe: keeps everything when no canonical account is present (avoids hiding the only account)", () => {
    // e.g. token exists but twist_instance_connection binding is missing/mismatched.
    const accounts = [{ provider: "linkedin", actorId: "actor-x" }];
    const { kept, orphans } = partitionOrphanHostedAccounts(
      accounts,
      hosted,
      new Set(["actor-different"]),
    );
    expect(kept).toEqual(accounts);
    expect(orphans).toEqual([]);
  });

  it("never touches non-hosted providers (multi-account OAuth connectors stay intact)", () => {
    const accounts = [
      { provider: "google", actorId: "a" },
      { provider: "google", actorId: "b" },
    ];
    const { kept, orphans } = partitionOrphanHostedAccounts(
      accounts,
      hosted,
      new Set(["a"]),
    );
    expect(kept).toEqual(accounts);
    expect(orphans).toEqual([]);
  });

  it("prunes only the provider that has a canonical binding present", () => {
    const accounts = [
      { provider: "linkedin", actorId: "li-bound" },
      { provider: "linkedin", actorId: "li-orphan" },
      { provider: "whatsapp", actorId: "wa-only" }, // no bound wa account present
    ];
    const { kept, orphans } = partitionOrphanHostedAccounts(
      accounts,
      new Set(["linkedin", "whatsapp"]),
      new Set(["li-bound"]),
    );
    expect(kept).toEqual([
      { provider: "linkedin", actorId: "li-bound" },
      { provider: "whatsapp", actorId: "wa-only" },
    ]);
    expect(orphans).toEqual([{ provider: "linkedin", actorId: "li-orphan" }]);
  });
});
