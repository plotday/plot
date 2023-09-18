import type { LoaderArgs } from "@remix-run/cloudflare";
import { redirect } from "@remix-run/cloudflare";

import { typedjson } from "remix-typedjson";
import { promiseHash } from "remix-utils";

import { Event } from "@plotday/db";

import { getUser } from "app/auth";
import { createServerClient } from "app/db";

export const loader = async ({ context, request }: LoaderArgs) => {
  const { response, supabase } = createServerClient(request, context);
  let user = await getUser(supabase);
  if (!user?.id) throw redirect("/login");

  return typedjson(
    {
      ...(await promiseHash({
        events: Event.GetRange(supabase, new Date()),
      })),
    },
    { headers: response.headers }
  );
};

export default function Prep() {
  return null;
}
