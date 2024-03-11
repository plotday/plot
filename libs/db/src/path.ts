import { parseDomain } from "parse-domain";

import type { SupabaseClient } from "./";
import { safeQuery } from "./query";

export function urlToPath(url: string) {
  return url.replaceAll("/", ".").replaceAll("-", "_");
}

export function pathToUrl(path: string) {
  return `/@/${path.replaceAll(".", "/").replaceAll("_", "-")}`;
}

export function nameToPath(name: string) {
  return name
    .replace(/[^a-zA-Z0-9]/g, "_")
    .replace(/_+/g, "_")
    .toLowerCase();
}

export async function emailToActivity(supabase: SupabaseClient, email: string) {
  const parts = email.split("@");
  let domain = parts[parts.length - 1];

  const domainRecord = safeQuery(
    await supabase
      .from("domain")
      .select("organization(name)")
      .eq("name", domain)
      .single()
  );
  if (!domainRecord.organization) {
    return {
      name: "Personal",
      path: "personal",
    };
  }

  const name =
    (domainRecord?.organization?.name as string | undefined) ?? "Work";
  const parsedDomain = parseDomain(domain);
  if (parsedDomain.type === "LISTED" && parsedDomain.domain) {
    return {
      name,
      path: parsedDomain.domain,
    };
  }
  let lastDotIndex = domain.lastIndexOf(".");
  if (lastDotIndex !== -1) {
    domain = domain.substring(0, lastDotIndex);
  }
  return {
    name,
    path: domain.replaceAll(".", "-"),
  };
}

export async function createActivities(
  supabaseAdmin: SupabaseClient,
  userId: string,
  email: string
) {
  const { path, name } = await emailToActivity(supabaseAdmin, email);
  return safeQuery(
    await supabaseAdmin
      .from("activity")
      .upsert(
        [
          {
            user_id: userId,
            name: "Meetings",
            path: `${path}.meetings`,
          },
          {
            user_id: userId,
            name,
            path,
          },
        ],
        { onConflict: "user_id,path", ignoreDuplicates: true }
      )
      .select()
  );
}
