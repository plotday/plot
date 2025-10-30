import { ContactAccess } from "@plotday/agent/tools/plot";

import type { Plot } from "./index";

function normalizeName(name: string | undefined | null): string | undefined {
  if (!name) return undefined;
  name = name.replace(/<?[^ ]+@[^ ]+>?/, "").trim();
  name = name.replace(/^([^, ]+),\s*(.+)/, "$2 $1");
  return name;
}

export async function addContacts(
  plot: Plot,
  contacts: Array<{ email: string; name?: string; avatar?: string }>
): Promise<void> {
  // Validate contact write access permissions
  plot.requireContactAccess(ContactAccess.Write);

  if (contacts.length === 0) return;

  const normalizedContacts = contacts.map((contact) => ({
    email: contact.email.toLowerCase(),
    name: normalizeName(contact.name),
    avatar: contact.avatar,
  }));

  const contactsToUpsert = normalizedContacts.map((contact) => ({
    email: contact.email,
    name: contact.name || null,
    avatar_url: contact.avatar || null,
  }));

  const result = await plot.supabase
    .from("contact")
    .upsert(contactsToUpsert, { onConflict: "user_id,email" });

  if (result.error) {
    throw new Error(`Failed to upsert contacts: ${result.error.message}`);
  }

  console.log(`Successfully upserted ${contacts.length} contacts`);
}
