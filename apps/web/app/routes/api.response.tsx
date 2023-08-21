import { useCallback } from "react";

import type { ActionArgs } from "@remix-run/cloudflare";
import { useFetcher } from "@remix-run/react";

import type { CalendarConfig, EventResponse } from "@plotday/cal";
import { respond } from "@plotday/cal";
import { getCredentials } from "@plotday/db";

import { getUser } from "app/auth";
import { createServerClient, safeQuery } from "app/db";
import { getEnv } from "app/env";

type ResponseBody = {
  eventId: number;
  response: EventResponse;
  email: string;
  isOrganizer: boolean;
};

export function useEventResponder() {
  const fetcher = useFetcher();
  return useCallback(
    (
      eventId: number,
      response: EventResponse,
      email: string,
      isOrganizer: boolean
    ) => {
      const body = {
        eventId,
        response,
        email,
        isOrganizer,
      } as ResponseBody;
      fetcher.submit(body, {
        method: "put",
        action: "/api/response",
        encType: "application/json",
      });
    },
    [fetcher]
  );
}

export const action = async ({ request, context }: ActionArgs) => {
  const { supabase, response } = createServerClient(request, context);
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
    case "PUT": {
      const body: ResponseBody = await request.json();
      const event = safeQuery(
        await supabase
          .from("event")
          .select("provider_id,calendar(provider_id,account_id)")
          .eq("id", body.eventId)
          .maybeSingle()
      );
      if (!event?.calendar) return new Response("Not found", { status: 404 });
      let credentials = await getCredentials(
        supabase,
        event.calendar.account_id
      );
      if (credentials.provider === "outlook" && body.response) {
        safeQuery(
          await supabase.from("response").upsert(
            {
              user_id: user.id,
              provider_id: event.provider_id,
              response: body.response,
            },
            { onConflict: "user_id,provider_id" }
          )
        );
      }
      await respond(
        calendarConfig,
        credentials,
        event.calendar.provider_id,
        event.provider_id,
        body.response,
        body.email,
        body.isOrganizer
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
