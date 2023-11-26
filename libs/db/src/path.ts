import { parseDomain } from "parse-domain";

import type { SupabaseClient } from "./";
import { safeQuery } from "./query";

export function urlToPath(url: string) {
  return url.replaceAll("+", "").replaceAll("-", "_").replaceAll(":", ".");
}

export function pathToUrl(path: string) {
  const parts = path.replaceAll("_", "-").split(".");
  return "/+" + [parts[0], parts.slice(1).join(":")].join("/");
}

export function nameToPath(name: string) {
  return name
    .replace(/[^a-zA-Z0-9]/g, "_")
    .replace(/_+/g, "_")
    .toLowerCase();
}

export async function emailToCategory(supabase: SupabaseClient, email: string) {
  const parts = email.split("@");
  let domain = parts[parts.length - 1];

  const domainRecord = safeQuery(
    await supabase
      .from("domain")
      .select("organization(name)")
      .eq("domain", domain)
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

export async function createCategories(
  supabaseAdmin: SupabaseClient,
  userId: number,
  email: string,
  updateDefault = false
) {
  const { path, name } = await emailToCategory(supabaseAdmin, email);
  safeQuery(
    await supabaseAdmin
      .from("category")
      .upsert(
        [
          {
            user_id: userId,
            name,
            path,
            priority: "O",
          },
          {
            user_id: userId,
            name: "Meetings",
            path: `${path}.meetings`,
            priority: "M",
          },
        ],
        { onConflict: "user_id,path", ignoreDuplicates: true }
      )
      .select()
  );

  if (updateDefault) {
    safeQuery(
      await supabaseAdmin
        .from("user")
        .update({ default_category: path })
        .eq("id", userId)
    );
  }

  return path;
}
