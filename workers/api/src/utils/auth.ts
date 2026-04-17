import type { Kysely } from "kysely";

import { verifyToken } from "@clerk/backend";

import type { DB } from "../db-types";

export type AuthUser = {
  id: string; // UUID from public."user"
  clerkId: string; // Clerk user ID (e.g., "user_2abc123")
  email: string;
  name: string | null;
};

/** Verified JWT claims from Clerk, returned even when DB user doesn't exist. */
export type ClerkClaims = {
  clerkId: string;
  email: string | undefined;
  name: string | undefined;
};

export type GetUserResult = {
  user: AuthUser | null;
  /** Non-null when JWT was verified but the DB user doesn't exist yet. */
  claims: ClerkClaims | null;
  error: any;
};

export async function getUser(
  db: Kysely<DB>,
  token: string,
  jwtKey: string
): Promise<GetUserResult> {
  try {
    const claims = await verifyToken(token, {
      jwtKey: atob(jwtKey),
    });
    const clerkId = claims.sub;

    // Check external_id first (set during activation via Clerk's updateUser)
    let userId = (claims as any).external_id as string | undefined;
    let email = (claims as any).email as string | undefined;
    let name: string | null = null;

    const clerkClaims: ClerkClaims = {
      clerkId,
      email,
      name: (claims as any).name as string | undefined,
    };

    if (userId) {
      // Fast path: UUID is in the JWT metadata
      const row = await db
        .selectFrom("user")
        .select(["email", "name", "clerk_id"])
        .where("id", "=", userId)
        .executeTakeFirst();
      if (row && row.clerk_id) {
        email = row.email;
        name = row.name;
      } else {
        // Either the external_id is stale/missing, or the row is a seed
        // placeholder with no clerk_id yet (e.g. kris@plot.day from the
        // system twist_instance seed). Fall through so /activate runs the
        // full new-user branch and links clerk_id.
        userId = undefined;
      }
    }

    if (!userId) {
      // Fallback: look up by clerk_id in users table
      const row = await db
        .selectFrom("user")
        .select(["id", "email", "name"])
        .where("clerk_id", "=", clerkId)
        .executeTakeFirst();
      if (row) {
        userId = row.id;
        email = row.email;
        name = row.name;
      } else {
        // New user — JWT is valid but user doesn't exist in DB yet.
        // Return claims so /activate can create the user.
        return { user: null, claims: clerkClaims, error: null };
      }
    }

    return {
      user: {
        id: userId,
        clerkId,
        email: email ?? "",
        name,
      },
      claims: null,
      error: null,
    };
  } catch (error) {
    // Decode the JWT payload without verifying it so we can log timing details.
    // This tells us whether the rejection is expiry/clock-skew vs. a signature
    // or issuer mismatch — without needing to reproduce the failure client-side.
    try {
      const payloadB64 = token.split(".")[1];
      if (payloadB64) {
        const payload = JSON.parse(atob(payloadB64));
        const nowSec = Math.floor(Date.now() / 1000);
        const exp = payload.exp as number | undefined;
        const nbf = payload.nbf as number | undefined;
        const iat = payload.iat as number | undefined;
        const expiredByMs = exp != null ? (nowSec - exp) * 1000 : null;
        const notYetValidMs = nbf != null ? (nbf - nowSec) * 1000 : null;
        console.error("JWT verification failed:", {
          error: String(error),
          serverTimeMs: Date.now(),
          iat: iat != null ? new Date(iat * 1000).toISOString() : null,
          nbf: nbf != null ? new Date(nbf * 1000).toISOString() : null,
          exp: exp != null ? new Date(exp * 1000).toISOString() : null,
          // Positive = expired N ms ago. Negative = still valid for N ms.
          expiredByMs,
          // Positive = not yet valid for N ms. Negative = already valid.
          notYetValidMs,
          sub: payload.sub as string | undefined,
        });
      }
    } catch {
      // Malformed JWT — log the raw error below.
    }
    console.error("JWT verification failed (raw):", error);
    return { user: null, claims: null, error };
  }
}
