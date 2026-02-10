import { type Actor, type ActorId, ActorType, type NewContact } from "@plotday/twister/plot";
import { ContactAccess } from "@plotday/twister/tools/plot";
import { createLogger } from "@plotday/worker-util";

import type { Plot } from "./index";

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

  // Convert "Last, First" to "First Last"
  name = name.replace(/^([^, ]+),\s*(.+)/, "$2 $1");

  // If nothing left after cleaning, return undefined
  return name || undefined;
}

export async function addContacts(
  plot: Plot,
  contacts: Array<NewContact>
): Promise<Actor[]> {
  // Validate contact write access permissions
  plot.requireContactAccess(ContactAccess.Write);

  if (contacts.length === 0) return [];

  const normalizedContacts = contacts.map((contact) => ({
    email: contact.email.toLowerCase(),
    name: normalizeName(contact.name),
    avatar: contact.avatar,
    source: contact.source,
  }));

  const contactsToUpsert = normalizedContacts.map((contact) => ({
    email: contact.email,
    name: contact.name || null,
    avatar_url: contact.avatar || null,
  }));

  // Use RPC function to support COALESCE - preserve existing name if new name is null
  const result = await plot.supabase.rpc("upsert_contacts", {
    contacts: contactsToUpsert,
  });

  if (result.error) {
    throw new Error(`Failed to upsert contacts: ${result.error.message}`);
  }

  // Map the upserted contacts to Actor type
  const actors: Actor[] = (result.data || []).map((contact: any) => {
    const actor: Actor = {
      id: contact.id as ActorId,
      type: contact.user_id ? ActorType.User : ActorType.Contact,
      name: contact.name || null,
    };
    // Email is always present for contacts (required field)
    if (contact.email) {
      actor.email = contact.email;
    }
    return actor;
  });

  // Store external account mappings for privacy compliance reporting
  const externalAccounts = normalizedContacts
    .filter((c) => c.source)
    .map((c) => {
      // Find the matching actor by email
      const actor = actors.find(
        (a) => a.email === c.email
      );
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
    const { error: ceaError } = await plot.supabase
      .from("contact_external_account")
      .upsert(
        externalAccounts.map((ea) => ({
          contact_id: ea.contact_id,
          provider: ea.provider,
          account_id: ea.account_id,
          data_fetched_at: new Date().toISOString(),
        })),
        { onConflict: "provider,account_id" }
      );

    if (ceaError) {
      // Log but don't fail the contact creation
      const logger = createLogger({ operation: "addContacts" });
      logger.error(
        "Failed to upsert contact_external_account",
        new Error(ceaError.message)
      );
    }
  }

  return actors;
}

export async function getActors(
  plot: Plot,
  ids: ActorId[]
): Promise<Actor[]> {
  // Validate contact read access permissions
  plot.requireContactAccess(ContactAccess.Read);

  if (ids.length === 0) return [];

  // Query the actor view to get actors by IDs
  const result = await plot.supabase
    .from("actor")
    .select("id, email, name, type")
    .in("id", ids);

  if (result.error) {
    throw new Error(`Failed to fetch actors: ${result.error.message}`);
  }

  // Map the database results to Actor type
  const actors: Actor[] = (result.data || []).map((actor) => {
    const actorObj: Actor = {
      id: actor.id as ActorId,
      type:
        actor.type === "user"
          ? ActorType.User
          : actor.type === "priority_twist"
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
