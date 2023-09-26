import { useCallback } from "react";

import type { ActionFunctionArgs } from "@remix-run/cloudflare";
import { useFetcher } from "@remix-run/react";

import type { CalendarConfig, Event } from "@plotday/cal";
import { update } from "@plotday/cal";
import { getCredentials } from "@plotday/db";

import { getUser } from "app/auth";
import { createServerClient, safeQuery } from "app/db";
import { getEnv } from "app/env";

type Changes = Partial<Event>;
type UpdateBody = {
  id: number;
  changes: Omit<Changes, "startsAt" | "endsAt" | "createdAt"> & {
    startsAt?: string;
    endsAt?: string;
  };
};

export function useEventUpdater() {
  const fetcher = useFetcher();
  return useCallback(
    (id: number, changes: Changes) => {
      const { startsAt, endsAt, ...otherChanges } = changes;
      const serializableChanges = {
        ...otherChanges,
        ...(startsAt ? { startsAt: startsAt.toISOString() } : {}),
        ...(endsAt ? { endsAt: endsAt.toISOString() } : {}),
      };
      const body = {
        id,
        changes: serializableChanges,
      } as UpdateBody;
      fetcher.submit(body, {
        method: "patch",
        action: "/api/event",
        encType: "application/json",
      });
    },
    [fetcher]
  );
}

export const action = async ({ request, context }: ActionFunctionArgs) => {
  let response: Response | undefined;
  let supabase;
  ({ supabase, response } = createServerClient(request, context));
  let user = await getUser(supabase);
  if (!user) return new Response("Unauthorized", { status: 401 });

  const env = getEnv(context);
  const calendarConfig: CalendarConfig = {
    googleClientId: env.GOOGLE_CLIENT_ID,
    googleOauthSecret: env.GOOGLE_OAUTH_SECRET,
    outlookClientId: env.MICROSOFT_CLIENT_ID,
    outlookOauthSecret: env.MICROSOFT_OAUTH_SECRET,
  };

  switch (request.method) {
    case "PATCH": {
      const body: UpdateBody = await request.json();
      const event = safeQuery(
        await supabase
          .from("event")
          .select("provider_id,calendar(provider_id,account_id)")
          .eq("id", body.id)
          .maybeSingle()
      );
      if (!event?.calendar) return new Response("Not found", { status: 404 });
      let credentials = await getCredentials(
        supabase,
        event.calendar.account_id
      );
      const { startsAt, endsAt, ...otherChanges } = body.changes;
      const deserializedChanges = {
        ...otherChanges,
        ...(startsAt ? { startsAt: new Date(startsAt) } : {}),
        ...(endsAt ? { endsAt: new Date(endsAt) } : {}),
      };
      await update(
        calendarConfig,
        credentials,
        event.calendar.provider_id,
        event.provider_id,
        deserializedChanges
      );
      return new Response(null, {
        headers: response.headers,
        status: 200,
      });
    }
    default:
      return new Response("Unsupported method", { status: 405 });
  }
};
