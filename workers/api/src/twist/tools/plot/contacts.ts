import { type Actor, type ActorId, ActorType, type NewContact } from "@plotday/twister/plot";
import { ContactAccess } from "@plotday/twister/tools/plot";
import { createLogger } from "@plotday/worker-util";

import { rpc } from "../../../rpc";
import { classifyInviteable } from "../../../state/contact-classifier";
import type { Plot } from "./index";

/**
 * True iff `err` is a Postgres unique-constraint violation (SQLSTATE 23505).
 * The PG driver attaches the code under either `code` or `cause.code`
 * depending on whether the error reaches us through Kysely's wrapping.
 */
function isUniqueViolation(err: unknown): boolean {
  if (!err || typeof err !== "object") return false;
  const e = err as { code?: string; cause?: { code?: string } };
  return e.code === "23505" || e.cause?.code === "23505";
}

function normalizeName(name: string | undefined | null): string | undefined {
  if (!name) return undefined;

  // Trim whitespace first
  name = name.trim();

  // If name looks like an email (no spaces and contains @), return undefined
  if (!name.includes(' ') && name.includes('@')) {
    return undefined;
  }

  // Strip trailing email addresses (with or without angle brackets)
  // Handles: "Kris Braun <kris@example.com>" or "Kris Braun kris@example.com"
  name = name.replace(/\s*<?[^ ]+@[^ ]+>?\s*$/, "").trim();

  // Strip Google Groups / mailing-list " via <group>" suffix.
  // "Jane Doe via Plot Support" → "Jane Doe", "'Google Developers' via Plot" → "'Google Developers'"
  name = name.replace(/\s+via\s+.+$/i, "").trim();

  // Strip wrapping single or double quotes left over from RFC 5322 quoted names.
  // e.g. "'Google Developers'" → "Google Developers"
  if (name.length >= 2) {
    const first = name[0];
    const last = name[name.length - 1];
    if ((first === "'" || first === '"') && first === last) {
      name = name.slice(1, -1).trim();
    }
  }

  // Convert "Last, First" to "First Last"
  name = name.replace(/^([^, ]+),\s*(.+)/, "$2 $1");

  // If nothing left after cleaning, return undefined
  return name || undefined;
}

export async function addContacts(
  plot: Plot,
  contacts: Array<NewContact>
): Promise<Actor[]> {
  if (contacts.length === 0) return [];

  const logger = createLogger({ operation: "addContacts" });

  // Separate contacts into two groups
  const contactsWithEmail = contacts.filter(
    (c): c is NewContact & { email: string } => !!c.email
  );
  const sourceOnlyContacts = contacts.filter(
    (c) => !c.email && c.source
  );

  // Warn about contacts that can't be resolved (no email, no source)
  const droppedCount = contacts.length - contactsWithEmail.length - sourceOnlyContacts.length;
  if (droppedCount > 0) {
    logger.warn(`Dropped ${droppedCount} contacts with neither email nor source`);
  }

  // --- Process contacts with email (existing upsert path) ---
  const normalizedContacts = Object.values(
    Object.fromEntries(
      contactsWithEmail.map((contact) => [
        contact.email.toLowerCase(),
        {
          email: contact.email.toLowerCase(),
          name: normalizeName(contact.name),
          avatar: contact.avatar,
          source: contact.source,
        },
      ])
    )
  );

  const contactsToUpsert = normalizedContacts.map((contact) => ({
    email: contact.email,
    name: contact.name || null,
    avatar_url: contact.avatar || null,
  }));

  // Use RPC function to support COALESCE - preserve existing name if new name is null
  const rpcResult = await rpc(plot.db, "upsert_contacts", {
    contacts: contactsToUpsert,
  });

  // Map the upserted contacts to Actor type
  const rpcData = Array.isArray(rpcResult) ? rpcResult : rpcResult ? [rpcResult] : [];
  const emailActors: Actor[] = rpcData.map((contact: any) => {
    const actor: Actor = {
      id: contact.id as ActorId,
      type: contact.user_id ? ActorType.User : ActorType.Contact,
      name: contact.name || null,
    };
    if (contact.email) {
      actor.email = contact.email;
    }
    return actor;
  });

  // Store external account mappings for email contacts
  const externalAccounts = normalizedContacts
    .filter((c) => c.source)
    .map((c) => {
      const actor = emailActors.find((a) => a.email === c.email);
      return actor
        ? {
            contact_id: actor.id,
            provider: c.source!.provider,
            account_id: c.source!.accountId,
          }
        : null;
    })
    .filter(Boolean) as Array<{
    contact_id: string;
    provider: string;
    account_id: string;
  }>;

  if (externalAccounts.length > 0) {
    try {
      await plot.db
        .insertInto("contact_external_account")
        .values(
          externalAccounts.map((ea) => ({
            contact_id: ea.contact_id,
            provider: ea.provider,
            account_id: ea.account_id,
            data_fetched_at: new Date().toISOString(),
          }))
        )
        .onConflict((oc) =>
          oc.columns(["provider", "account_id"]).doUpdateSet((eb) => ({
            contact_id: eb.ref("excluded.contact_id"),
            data_fetched_at: eb.ref("excluded.data_fetched_at"),
          }))
        )
        .execute();
    } catch (ceaError) {
      logger.error(
        "Failed to upsert contact_external_account",
        ceaError instanceof Error ? ceaError : new Error(String(ceaError))
      );
    }

    // Email merge: the ON CONFLICT clause above already handles the case where
    // a contact_external_account mapping previously pointed to a different (email-less)
    // contact — it updates the mapping to point to the email-matched contact.
  }

  // --- Process source-only contacts (no email, has provider ID) ---
  const sourceActors: Actor[] = [];

  for (const contact of sourceOnlyContacts) {
    const source = contact.source!;
    try {
      // Look up existing contact via contact_external_account
      const existingMapping = await plot.db
        .selectFrom("contact_external_account")
        .select("contact_id")
        .where("provider", "=", source.provider)
        .where("account_id", "=", source.accountId)
        .executeTakeFirst();

      if (existingMapping) {
        // Found existing contact — fetch it and optionally update name/avatar
        const existingContact = await plot.db
          .selectFrom("contact")
          .select(["id", "user_id", "name", "email", "avatar_url"])
          .where("id", "=", existingMapping.contact_id)
          .executeTakeFirst();

        if (existingContact) {
          // Update name/avatar if currently null and new values provided (COALESCE pattern)
          const normalizedName = normalizeName(contact.name);
          const needsUpdate =
            (!existingContact.name && normalizedName) ||
            (!existingContact.avatar_url && contact.avatar);

          if (needsUpdate) {
            await plot.db
              .updateTable("contact")
              .set({
                ...((!existingContact.name && normalizedName)
                  ? { name: normalizedName }
                  : {}),
                ...((!existingContact.avatar_url && contact.avatar)
                  ? { avatar_url: contact.avatar }
                  : {}),
              })
              .where("id", "=", existingContact.id)
              .execute();
          }

          const actor: Actor = {
            id: existingContact.id as ActorId,
            type: existingContact.user_id ? ActorType.User : ActorType.Contact,
            name: normalizedName || existingContact.name || null,
          };
          if (existingContact.email) {
            actor.email = existingContact.email;
          }
          sourceActors.push(actor);
        }
      } else {
        // Insert contact + mapping in one transaction so the contact INSERT
        // rolls back if a concurrent caller already created the mapping.
        // Without this, a race produces an orphaned contact row with no
        // contact_external_account entry (and the second caller's mapping
        // insert fails with a unique-violation that gets swallowed below).
        const normalizedName = normalizeName(contact.name);
        let inserted: { id: string; name: string | null } | null = null;
        try {
          inserted = await plot.db.transaction().execute(async (trx) => {
            const newContact = await trx
              .insertInto("contact")
              .values({
                email: null,
                name: normalizedName || null,
                avatar_url: contact.avatar || null,
                inviteable: classifyInviteable(null, normalizedName || null),
              })
              .returning(["id", "name"])
              .executeTakeFirstOrThrow();

            await trx
              .insertInto("contact_external_account")
              .values({
                contact_id: newContact.id,
                provider: source.provider,
                account_id: source.accountId,
                data_fetched_at: new Date().toISOString(),
              })
              .execute();

            return newContact;
          });
        } catch (txError) {
          // Concurrent caller won the race on (provider, account_id). Postgres
          // returned 23505 (unique_violation), the transaction rolled back, so
          // no orphan contact was created. Fall through and re-query for the
          // winner's contact_id.
          if (!isUniqueViolation(txError)) throw txError;
        }

        if (inserted) {
          const actor: Actor = {
            id: inserted.id as ActorId,
            type: ActorType.Contact,
            name: inserted.name || null,
          };
          sourceActors.push(actor);
        } else {
          // Race lost — the winner already wrote the mapping. Resolve through
          // the existing mapping path.
          const winnerMapping = await plot.db
            .selectFrom("contact_external_account")
            .select("contact_id")
            .where("provider", "=", source.provider)
            .where("account_id", "=", source.accountId)
            .executeTakeFirst();

          if (winnerMapping) {
            const winnerContact = await plot.db
              .selectFrom("contact")
              .select(["id", "user_id", "name", "email"])
              .where("id", "=", winnerMapping.contact_id)
              .executeTakeFirst();
            if (winnerContact) {
              const actor: Actor = {
                id: winnerContact.id as ActorId,
                type: winnerContact.user_id ? ActorType.User : ActorType.Contact,
                name: winnerContact.name || null,
              };
              if (winnerContact.email) {
                actor.email = winnerContact.email;
              }
              sourceActors.push(actor);
            }
          }
        }
      }
    } catch (error) {
      logger.error(
        "Failed to process source-only contact",
        error instanceof Error ? error : new Error(String(error))
      );
    }
  }

  return [...emailActors, ...sourceActors];
}

export async function getActors(
  plot: Plot,
  ids: ActorId[]
): Promise<Actor[]> {
  // Validate contact read access permissions
  plot.requireContactAccess(ContactAccess.Read);

  if (ids.length === 0) return [];

  // Query the actor view to get actors by IDs
  const result = await plot.db
    .selectFrom("actor")
    .select(["id", "email", "name", "type"])
    .where("id", "in", ids)
    .execute();

  // Map the database results to Actor type
  const actors: Actor[] = result.map((actor) => {
    const actorObj: Actor = {
      id: actor.id as ActorId,
      type:
        actor.type === "user"
          ? ActorType.User
          : actor.type === "twist_instance"
          ? ActorType.Twist
          : ActorType.Contact,
      name: actor.name || null,
    };
    // Only include email if it exists
    if (actor.email) {
      actorObj.email = actor.email;
    }
    return actorObj;
  });

  return actors;
}
