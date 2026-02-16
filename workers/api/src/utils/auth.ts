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
        .select(["email", "name"])
        .where("id", "=", userId)
        .executeTakeFirst();
      if (row) {
        email = row.email;
        name = row.name;
      } else {
        // external_id is stale or missing in DB; fall back to clerk_id lookup
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
    console.error("JWT verification failed:", error);
    return { user: null, claims: null, error };
  }
}
