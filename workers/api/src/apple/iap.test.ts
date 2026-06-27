import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";

import { createDb, type DB } from "../db";
import type { Bindings } from "../env";
import {
  APPLE_BUNDLE_ID,
  IAP_ADDON_PRODUCT_TO_COUNT,
  IAP_PRODUCT_TO_PLAN,
  IAP_TWIST_ADDON_PRODUCT_TO_COUNT,
  applyAppleAddonTransactionToUser,
  applyAppleTransactionToUser,
  applyAppleTwistAddonTransactionToUser,
  decodeJws,
  decodeTransaction,
  isAddonProduct,
  isTwistAddonProduct,
  verifyAppleJws,
  type JwsTransactionPayload,
} from "./iap";

const DATABASE_URL = process.env.DATABASE_URL;

/** Sentinel thrown to force the seeding transaction to roll back. */
class Rollback extends Error {}

/** Build a minimal decoded JwsTransactionPayload for a given productId. */
function makeTxn(
  overrides: Partial<JwsTransactionPayload> & { productId: string }
): JwsTransactionPayload {
  const now = Date.now();
  return {
    transactionId: "2000000999999999",
    originalTransactionId: "2000000999999999",
    bundleId: APPLE_BUNDLE_ID,
    purchaseDate: now,
    originalPurchaseDate: now,
    expiresDate: now + 30 * 24 * 60 * 60 * 1000,
    ...overrides,
  };
}

/** Build a JWS with a caller-supplied header so we can exercise the
 *  verifier's structural checks without a real Apple chain. */
function makeJwsWithHeader(
  header: Record<string, unknown>,
  payload: Record<string, unknown>
): string {
  const h = Buffer.from(JSON.stringify(header)).toString("base64url");
  const b = Buffer.from(JSON.stringify(payload)).toString("base64url");
  return `${h}.${b}.signature`;
}

/**
 * Constructs an unsigned JWS (header.payload.signature). Apple's
 * StoreKit 2 transactions arrive signed by Apple, but our decoder
 * verifies only that the structure is right and the payload's
 * `bundleId` / `productId` match. The signature segment is therefore
 * a placeholder.
 */
function makeFakeJws(payload: Record<string, unknown>): string {
  const header = Buffer.from(JSON.stringify({ alg: "ES256" })).toString(
    "base64url"
  );
  const body = Buffer.from(JSON.stringify(payload)).toString("base64url");
  return `${header}.${body}.signature`;
}

describe("apple/iap", () => {
  it("exposes the Plot product ID → plan mapping", () => {
    expect(IAP_PRODUCT_TO_PLAN["day.plot.app.pro_monthly"]).toBe("pro");
    // core_monthly is no longer a valid IAP product (Core plan dropped)
    expect(IAP_PRODUCT_TO_PLAN["day.plot.app.core_monthly"]).toBeUndefined();
  });

  it("decodes a well-formed JWS into the expected payload", () => {
    const payload: Partial<JwsTransactionPayload> = {
      transactionId: "2000000123456789",
      originalTransactionId: "2000000123456789",
      bundleId: APPLE_BUNDLE_ID,
      productId: "day.plot.app.pro_monthly",
      purchaseDate: 1700000000000,
      originalPurchaseDate: 1700000000000,
      expiresDate: 1702592000000,
      environment: "Production",
    };
    const decoded = decodeJws<JwsTransactionPayload>(makeFakeJws(payload));
    expect(decoded.productId).toBe("day.plot.app.pro_monthly");
    expect(decoded.bundleId).toBe(APPLE_BUNDLE_ID);
    expect(decoded.transactionId).toBe("2000000123456789");
  });

  it("rejects malformed JWS", () => {
    expect(() => decodeJws("not.a.jws.extra")).toThrowError(/Invalid JWS/);
    expect(() => decodeJws("missing-dots")).toThrowError(/Invalid JWS/);
  });

  it("rejects bundleId from a different app", () => {
    const payload: Partial<JwsTransactionPayload> = {
      transactionId: "2000000111111111",
      originalTransactionId: "2000000111111111",
      bundleId: "com.someone.else",
      productId: "day.plot.app.pro_monthly",
      purchaseDate: 1700000000000,
      originalPurchaseDate: 1700000000000,
    };
    expect(() => decodeTransaction(makeFakeJws(payload))).toThrowError(
      /bundleId mismatch/
    );
  });

  it("rejects unknown productId", () => {
    const payload: Partial<JwsTransactionPayload> = {
      transactionId: "2000000222222222",
      originalTransactionId: "2000000222222222",
      bundleId: APPLE_BUNDLE_ID,
      productId: "day.plot.app.unknown_addon",
      purchaseDate: 1700000000000,
      originalPurchaseDate: 1700000000000,
    };
    expect(() => decodeTransaction(makeFakeJws(payload))).toThrowError(
      /Unknown Apple productId/
    );
  });

  it("accepts a recognized productId for the Pro tier", () => {
    const payload: Partial<JwsTransactionPayload> = {
      transactionId: "2000000333333333",
      originalTransactionId: "2000000333333333",
      bundleId: APPLE_BUNDLE_ID,
      productId: "day.plot.app.pro_monthly",
      purchaseDate: 1700000000000,
      originalPurchaseDate: 1700000000000,
      expiresDate: 1702592000000,
    };
    const txn = decodeTransaction(makeFakeJws(payload));
    expect(txn.productId).toBe("day.plot.app.pro_monthly");
  });

  it("exposes the add-on product → count mapping", () => {
    expect(IAP_ADDON_PRODUCT_TO_COUNT["day.plot.app.addon_1"]).toBe(1);
    expect(IAP_ADDON_PRODUCT_TO_COUNT["day.plot.app.addon_3"]).toBe(3);
    expect(isAddonProduct("day.plot.app.addon_3")).toBe(true);
    expect(isAddonProduct("day.plot.app.pro_monthly")).toBe(false);
  });

  it("exposes the twist add-on product → count mapping", () => {
    expect(IAP_TWIST_ADDON_PRODUCT_TO_COUNT["day.plot.app.twist_addon_1"]).toBe(1);
    expect(IAP_TWIST_ADDON_PRODUCT_TO_COUNT["day.plot.app.twist_addon_2"]).toBe(2);
    expect(IAP_TWIST_ADDON_PRODUCT_TO_COUNT["day.plot.app.twist_addon_3"]).toBe(3);
    expect(isTwistAddonProduct("day.plot.app.twist_addon_2")).toBe(true);
    expect(isTwistAddonProduct("day.plot.app.addon_2")).toBe(false);
    expect(isTwistAddonProduct("day.plot.app.pro_monthly")).toBe(false);
  });

  it("decodeTransaction accepts a twist add-on product", () => {
    const payload: Partial<JwsTransactionPayload> = {
      transactionId: "2000000555555555",
      originalTransactionId: "2000000555555555",
      bundleId: APPLE_BUNDLE_ID,
      productId: "day.plot.app.twist_addon_2",
      purchaseDate: 1700000000000,
      originalPurchaseDate: 1700000000000,
      expiresDate: 1702592000000,
    };
    const txn = decodeTransaction(makeFakeJws(payload));
    expect(txn.productId).toBe("day.plot.app.twist_addon_2");
  });

  it("decodeTransaction accepts an add-on product", () => {
    const payload: Partial<JwsTransactionPayload> = {
      transactionId: "2000000444444444",
      originalTransactionId: "2000000444444444",
      bundleId: APPLE_BUNDLE_ID,
      productId: "day.plot.app.addon_2",
      purchaseDate: 1700000000000,
      originalPurchaseDate: 1700000000000,
      expiresDate: 1702592000000,
    };
    const txn = decodeTransaction(makeFakeJws(payload));
    expect(txn.productId).toBe("day.plot.app.addon_2");
  });

  // -----------------------------------------------------------------
  // verifyAppleJws — structural checks that don't need a real Apple
  // signed chain. End-to-end verification (real cert chain + real
  // signature) is exercised against Apple's sandbox in manual QA.
  // -----------------------------------------------------------------

  it("verifyAppleJws rejects a malformed JWS", async () => {
    await expect(verifyAppleJws("not-a-jws")).rejects.toThrowError(
      /Invalid JWS/
    );
    await expect(verifyAppleJws("a.b")).rejects.toThrowError(/Invalid JWS/);
  });

  it("verifyAppleJws rejects a non-ES256 algorithm", async () => {
    const jws = makeJwsWithHeader(
      { alg: "HS256", x5c: ["AA"] },
      { hello: "world" }
    );
    await expect(verifyAppleJws(jws)).rejects.toThrowError(
      /Unsupported JWS alg/
    );
  });

  it("verifyAppleJws rejects a JWS with no x5c chain", async () => {
    const jws = makeJwsWithHeader({ alg: "ES256" }, { hello: "world" });
    await expect(verifyAppleJws(jws)).rejects.toThrowError(/missing x5c/);
  });

  it("verifyAppleJws rejects a chain that doesn't anchor at Apple Root CA G3", async () => {
    // A single self-signed cert ⇒ chain root is the cert itself, whose
    // fingerprint won't match the pinned Apple Root CA G3 hash. We use
    // a minimal but parseable X.509 v3 DER built by hand: just enough
    // structure to get past the parser before the root-pin check fails.
    const bogusCertDer = makeMinimalSelfSignedDer();
    const x5c = Buffer.from(bogusCertDer).toString("base64");
    const jws = makeJwsWithHeader(
      { alg: "ES256", x5c: [x5c] },
      { hello: "world" }
    );
    await expect(verifyAppleJws(jws)).rejects.toThrowError(
      /does not anchor at Apple Root CA - G3/
    );
  });
});

// -----------------------------------------------------------------
// applyAppleTransactionToUser — DB tests (skipped when no DATABASE_URL)
// -----------------------------------------------------------------

describe.skipIf(!DATABASE_URL)(
  "applyAppleTransactionToUser",
  () => {
    it("resolves legacy core_monthly to plan=free (no throw)", async () => {
      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();

      try {
        await db.transaction().execute(async (trx: Kysely<DB>) => {
          await sql`SET LOCAL session_replication_role = replica`.execute(trx);

          // Arrange: seed a minimal user_subscription row so the upsert lands
          await trx
            .insertInto("user_subscription")
            .values({
              user_id: userId,
              plan: "free",
              status: "active",
              origin: "app_store",
              billing_cycle_start: new Date().toISOString(),
              billing_cycle_end: new Date(
                Date.now() + 8.64e7
              ).toISOString(),
            })
            .execute();

          // Act: send a legacy core_monthly transaction — must NOT throw
          const txn = makeTxn({ productId: "day.plot.app.core_monthly" });
          const result = await applyAppleTransactionToUser(trx, userId, txn);

          await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

          // Assert: resolves to free, not a 500-loop throw
          expect(result.plan).toBe("free");

          const row = await trx
            .selectFrom("user_subscription")
            .selectAll()
            .where("user_id", "=", userId)
            .executeTakeFirstOrThrow();

          expect(row.plan).toBe("free");
          expect(row.apple_product_id).toBe("day.plot.app.core_monthly");

          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }
    });

    it("reports the prior Stripe row and clears stripe_subscription_id on convert", async () => {
      const db = createDb({ DATABASE_URL } as unknown as Bindings);
      const userId = randomUUID();

      try {
        await db.transaction().execute(async (trx: Kysely<DB>) => {
          await sql`SET LOCAL session_replication_role = replica`.execute(trx);

          // Arrange: user with a Stripe Pro trial row
          await trx
            .insertInto("user_subscription")
            .values({
              user_id: userId,
              plan: "pro",
              status: "trialing",
              origin: "stripe",
              stripe_customer_id: "cus_test",
              stripe_subscription_id: "sub_test",
              billing_cycle_start: new Date().toISOString(),
              billing_cycle_end: new Date(
                Date.now() + 8.64e7
              ).toISOString(),
            })
            .execute();

          const txn = makeTxn({ productId: "day.plot.app.pro_monthly" });

          const result = await applyAppleTransactionToUser(trx, userId, txn);

          await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

          expect(result.previous).toMatchObject({
            origin: "stripe",
            status: "trialing",
            plan: "pro",
            stripeSubscriptionId: "sub_test",
            stripeCustomerId: "cus_test",
          });

          const row = await trx
            .selectFrom("user_subscription")
            .selectAll()
            .where("user_id", "=", userId)
            .executeTakeFirstOrThrow();

          expect(row.origin).toBe("app_store");
          expect(row.stripe_subscription_id).toBeNull();

          throw new Rollback();
        });
      } catch (e) {
        if (!(e instanceof Rollback)) throw e;
      } finally {
        await db.destroy();
      }
    });
  }
);

describe.skipIf(!DATABASE_URL)("applyAppleAddonTransactionToUser", () => {
  /** Seed a paid app_store plan row, apply an add-on txn, return the row. */
  async function applyAndRead(
    txnOverrides: Partial<JwsTransactionPayload> & { productId: string }
  ) {
    const db = createDb({ DATABASE_URL } as unknown as Bindings);
    const userId = randomUUID();
    let row: Record<string, unknown> | undefined;
    try {
      await db.transaction().execute(async (trx: Kysely<DB>) => {
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);
        await trx
          .insertInto("user_subscription")
          .values({
            user_id: userId,
            plan: "pro",
            status: "active",
            origin: "app_store",
            apple_original_transaction_id: "2000000000000001",
            apple_product_id: "day.plot.app.pro_monthly",
            billing_cycle_start: new Date().toISOString(),
            billing_cycle_end: new Date(Date.now() + 8.64e7).toISOString(),
          })
          .execute();

        await applyAppleAddonTransactionToUser(trx, userId, makeTxn(txnOverrides));

        row = await trx
          .selectFrom("user_subscription")
          .selectAll()
          .where("user_id", "=", userId)
          .executeTakeFirstOrThrow();
        await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);
        throw new Rollback();
      });
    } catch (e) {
      if (!(e instanceof Rollback)) throw e;
    } finally {
      await db.destroy();
    }
    return row!;
  }

  it("sets the add-on count and tracking columns; leaves the plan intact", async () => {
    const row = await applyAndRead({
      productId: "day.plot.app.addon_3",
      originalTransactionId: "2000000000000099",
    });
    expect(row.premium_connection_addons).toBe(3);
    expect(row.apple_addon_product_id).toBe("day.plot.app.addon_3");
    expect(row.apple_addon_original_transaction_id).toBe("2000000000000099");
    // Plan fields untouched.
    expect(row.plan).toBe("pro");
    expect(row.apple_product_id).toBe("day.plot.app.pro_monthly");
  });

  it("resets the add-on count to 0 when the add-on subscription has expired", async () => {
    const row = await applyAndRead({
      productId: "day.plot.app.addon_2",
      expiresDate: Date.now() - 1000,
    });
    expect(row.premium_connection_addons).toBe(0);
  });

  it("resets the add-on count to 0 when revoked", async () => {
    const row = await applyAndRead({
      productId: "day.plot.app.addon_3",
      revocationDate: Date.now(),
    });
    expect(row.premium_connection_addons).toBe(0);
  });

  it("applies an add-on tier to a FREE-plan user (no paid plan required)", async () => {
    const db = createDb({ DATABASE_URL } as unknown as Bindings);
    const userId = randomUUID();
    let addons: number | undefined;
    let rowAddons: number | null | undefined;
    try {
      await db.transaction().execute(async (trx: Kysely<DB>) => {
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);
        await trx
          .insertInto("user_subscription")
          .values({
            user_id: userId,
            plan: "free",
            status: "active",
            origin: "app_store",
            billing_cycle_start: new Date().toISOString(),
            billing_cycle_end: new Date(Date.now() + 8.64e7).toISOString(),
          })
          .execute();

        const result = await applyAppleAddonTransactionToUser(
          trx,
          userId,
          makeTxn({
            productId: "day.plot.app.addon_1",
            originalTransactionId: randomUUID(),
            expiresDate: Date.now() + 60_000,
            revocationDate: undefined,
          })
        );
        addons = result.addons;

        const row = await trx
          .selectFrom("user_subscription")
          .select("premium_connection_addons")
          .where("user_id", "=", userId)
          .executeTakeFirstOrThrow();
        rowAddons = row.premium_connection_addons;

        await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);
        throw new Rollback();
      });
    } catch (e) {
      if (!(e instanceof Rollback)) throw e;
    } finally {
      await db.destroy();
    }
    expect(addons).toBe(1);
    expect(rowAddons).toBe(1);
  });
});

describe.skipIf(!DATABASE_URL)("applyAppleTwistAddonTransactionToUser", () => {
  /** Seed a Free subscription row, apply a twist add-on txn, return the row. */
  async function applyTwistAndRead(
    txnOverrides: Partial<JwsTransactionPayload> & { productId: string }
  ) {
    const db = createDb({ DATABASE_URL } as unknown as Bindings);
    const userId = randomUUID();
    let row: Record<string, unknown> | undefined;
    try {
      await db.transaction().execute(async (trx: Kysely<DB>) => {
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);
        await trx
          .insertInto("user_subscription")
          .values({
            user_id: userId,
            plan: "free",
            status: "active",
            origin: "app_store",
            billing_cycle_start: new Date().toISOString(),
            billing_cycle_end: new Date(Date.now() + 8.64e7).toISOString(),
          })
          .execute();

        await applyAppleTwistAddonTransactionToUser(trx, userId, makeTxn(txnOverrides));

        row = await trx
          .selectFrom("user_subscription")
          .selectAll()
          .where("user_id", "=", userId)
          .executeTakeFirstOrThrow();
        await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);
        throw new Rollback();
      });
    } catch (e) {
      if (!(e instanceof Rollback)) throw e;
    } finally {
      await db.destroy();
    }
    return row!;
  }

  it("sets twist_addon_count and tracking columns; leaves plan and connection add-on fields intact", async () => {
    const row = await applyTwistAndRead({
      productId: "day.plot.app.twist_addon_2",
      originalTransactionId: "2000000000000200",
    });
    expect(row.twist_addon_count).toBe(2);
    expect(row.apple_twist_addon_product_id).toBe("day.plot.app.twist_addon_2");
    expect(row.apple_twist_addon_original_transaction_id).toBe("2000000000000200");
    // Plan and connection add-on columns untouched.
    expect(row.plan).toBe("free");
    expect(row.premium_connection_addons).toBe(0);
    expect(row.apple_addon_original_transaction_id).toBeNull();
  });

  it("resets twist_addon_count to 0 when the twist add-on subscription has expired", async () => {
    const row = await applyTwistAndRead({
      productId: "day.plot.app.twist_addon_3",
      expiresDate: Date.now() - 1000,
    });
    expect(row.twist_addon_count).toBe(0);
  });

  it("resets twist_addon_count to 0 when revoked", async () => {
    const row = await applyTwistAndRead({
      productId: "day.plot.app.twist_addon_2",
      revocationDate: Date.now(),
    });
    expect(row.twist_addon_count).toBe(0);
  });

  it("applying a connection add-on does NOT touch twist_addon_count", async () => {
    const db = createDb({ DATABASE_URL } as unknown as Bindings);
    const userId = randomUUID();
    let row: Record<string, unknown> | undefined;
    try {
      await db.transaction().execute(async (trx: Kysely<DB>) => {
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);
        await trx
          .insertInto("user_subscription")
          .values({
            user_id: userId,
            plan: "free",
            status: "active",
            origin: "app_store",
            twist_addon_count: 2,
            billing_cycle_start: new Date().toISOString(),
            billing_cycle_end: new Date(Date.now() + 8.64e7).toISOString(),
          })
          .execute();

        await applyAppleAddonTransactionToUser(
          trx,
          userId,
          makeTxn({ productId: "day.plot.app.addon_1", expiresDate: Date.now() + 60_000 })
        );

        row = await trx
          .selectFrom("user_subscription")
          .selectAll()
          .where("user_id", "=", userId)
          .executeTakeFirstOrThrow();
        await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);
        throw new Rollback();
      });
    } catch (e) {
      if (!(e instanceof Rollback)) throw e;
    } finally {
      await db.destroy();
    }
    // Connection add-on was applied; twist_addon_count must remain unchanged.
    expect(row!.premium_connection_addons).toBe(1);
    expect(row!.twist_addon_count).toBe(2);
  });

  it("applying a twist add-on does NOT touch premium_connection_addons", async () => {
    const db = createDb({ DATABASE_URL } as unknown as Bindings);
    const userId = randomUUID();
    let row: Record<string, unknown> | undefined;
    try {
      await db.transaction().execute(async (trx: Kysely<DB>) => {
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);
        await trx
          .insertInto("user_subscription")
          .values({
            user_id: userId,
            plan: "free",
            status: "active",
            origin: "app_store",
            premium_connection_addons: 3,
            billing_cycle_start: new Date().toISOString(),
            billing_cycle_end: new Date(Date.now() + 8.64e7).toISOString(),
          })
          .execute();

        await applyAppleTwistAddonTransactionToUser(
          trx,
          userId,
          makeTxn({ productId: "day.plot.app.twist_addon_1", expiresDate: Date.now() + 60_000 })
        );

        row = await trx
          .selectFrom("user_subscription")
          .selectAll()
          .where("user_id", "=", userId)
          .executeTakeFirstOrThrow();
        await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);
        throw new Rollback();
      });
    } catch (e) {
      if (!(e instanceof Rollback)) throw e;
    } finally {
      await db.destroy();
    }
    // Twist add-on was applied; premium_connection_addons must remain unchanged.
    expect(row!.twist_addon_count).toBe(1);
    expect(row!.premium_connection_addons).toBe(3);
  });
});

/** Build a minimal X.509 v3 cert (DER) that's just well-formed enough
 *  for the verifier to parse it before rejecting on the root pin. We
 *  don't need a valid signature here — the chain anchor check fails
 *  first. */
function makeMinimalSelfSignedDer(): Uint8Array {
  const concat = (...parts: Uint8Array[]): Uint8Array => {
    const total = parts.reduce((n, p) => n + p.length, 0);
    const out = new Uint8Array(total);
    let off = 0;
    for (const p of parts) {
      out.set(p, off);
      off += p.length;
    }
    return out;
  };
  const bytes = (...vs: number[]) => Uint8Array.from(vs);
  const encodeLen = (n: number): Uint8Array => {
    if (n < 0x80) return bytes(n);
    const out: number[] = [];
    let v = n;
    while (v > 0) {
      out.unshift(v & 0xff);
      v >>= 8;
    }
    return bytes(0x80 | out.length, ...out);
  };
  const tlv = (t: number, content: Uint8Array) =>
    concat(bytes(t), encodeLen(content.length), content);

  const version = tlv(0xa0, tlv(0x02, bytes(0x02))); // [0] EXPLICIT INTEGER 2
  const serial = tlv(0x02, bytes(0x01)); // INTEGER 1
  // ecdsa-with-SHA256 alg id (used in both inner & outer)
  const sigAlg = tlv(
    0x30,
    tlv(0x06, bytes(0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02))
  );
  const emptyName = tlv(0x30, new Uint8Array(0));
  const utcTime = (s: string) =>
    tlv(0x17, new TextEncoder().encode(s));
  // 2000-01-01 → 2099-01-01: always inside the validity window.
  const validity = tlv(
    0x30,
    concat(utcTime("000101000000Z"), utcTime("990101000000Z"))
  );
  // Minimal EC SPKI for P-256, with an obviously-zero public key (we
  // never use it). algorithm = SEQ { id-ecPublicKey, P-256 }, then a
  // BIT STRING containing an uncompressed point of zeros.
  const idEcPublicKey = tlv(
    0x06,
    bytes(0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01)
  );
  const p256Oid = tlv(
    0x06,
    bytes(0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07)
  );
  const algId = tlv(0x30, concat(idEcPublicKey, p256Oid));
  const pubKeyBytes = concat(bytes(0x00, 0x04), new Uint8Array(64));
  const subjectPubKey = tlv(0x03, pubKeyBytes);
  const spki = tlv(0x30, concat(algId, subjectPubKey));

  const tbs = tlv(
    0x30,
    concat(version, serial, sigAlg, emptyName, validity, emptyName, spki)
  );

  // Signature value: BIT STRING { 0x00, DER ECDSA-Sig-Value }. We
  // never reach the chain-signature check, so a placeholder SEQUENCE
  // is fine.
  const innerSig = tlv(
    0x30,
    concat(tlv(0x02, bytes(0x01)), tlv(0x02, bytes(0x01)))
  );
  const sigValue = tlv(0x03, concat(bytes(0x00), innerSig));

  return tlv(0x30, concat(tbs, sigAlg, sigValue));
}
