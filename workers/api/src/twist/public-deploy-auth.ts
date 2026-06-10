import { type Kysely } from "kysely";

import { type DB } from "../db";

export type PublicDeployCheck =
  | { ok: true }
  | { ok: false; message: string };

/**
 * Authorize a deploy targeting the `public` environment.
 *
 * Only publishers with `can_publish_public = true` may publish end-user-visible
 * connectors. Non-public environments are always allowed here (other auth is
 * handled in the route). Returns a clear, publisher-named message on denial so
 * the CLI surfaces something actionable.
 */
export async function checkPublicDeployAllowed(
  db: Kysely<DB>,
  environment: string,
  resolvedPublisherId: number | null,
): Promise<PublicDeployCheck> {
  if (environment !== "public") return { ok: true };

  if (resolvedPublisherId === null) {
    return {
      ok: false,
      message:
        "Forbidden: a publisher is required to deploy to the public environment.",
    };
  }

  const publisher = await db
    .selectFrom("publisher")
    .select(["name", "can_publish_public"])
    // publisher.id is a bigint column; the codebase compares it to JS numbers
    // with an `as any` cast (see workers/api/src/sdk/twist.ts).
    .where("id", "=", resolvedPublisherId as never)
    .executeTakeFirst();

  if (!publisher) {
    return {
      ok: false,
      message: "Forbidden: publisher not found for the public deploy.",
    };
  }

  if (!publisher.can_publish_public) {
    return {
      ok: false,
      message:
        `Forbidden: publisher "${publisher.name}" is not approved to publish ` +
        `to the public environment. Contact Plot to request public-publish access.`,
    };
  }

  return { ok: true };
}
