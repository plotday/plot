import { useCallback } from "react";

import type { ActionArgs } from "@remix-run/cloudflare";
import { useFetcher } from "@remix-run/react";

import type { CalendarConfig, EventResponse } from "@plotday/cal";
import { respond } from "@plotday/cal";
import type { Attendance } from "@plotday/db";
import { getCredentials } from "@plotday/db";

import { getUser } from "app/auth";
import { createServerClient, safeQuery } from "app/db";
import { getEnv } from "app/env";

type ResponseBody = {
  eventId: number;
  attendance: Attendance;
  email: string;
  isOrganizer: boolean;
};

export function useEventResponder() {
  const fetcher = useFetcher();
  return useCallback(
    (
      eventId: number,
      attendance: Attendance,
      email: string,
      isOrganizer: boolean
    ) => {
      const body = {
        eventId,
        attendance,
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
  const { supabase } = createServerClient(request, context);
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
      let response: EventResponse;
      switch (body.attendance) {
        case "attend":
          response = "accepted";
          break;
        case "skip":
          response = "declined";
          break;
        default:
        case "if-possible":
          response = "tentative";
          break;
      }

      const contactIds = safeQuery(
        await supabase
          .from("contact")
          .select("id")
          .eq("user_id", user.id)
          .eq("contact_user_id", user.id)
      )?.map((c) => c.id);
      if (!contactIds)
        return new Response("Contact not found", { status: 404 });

      safeQuery(
        await supabase.from("response").upsert(
          {
            user_id: user.id,
            provider_id: event.provider_id,
            attendance: body.attendance,
          },
          { onConflict: "user_id,provider_id" }
        )
      );

      safeQuery(
        await supabase
          .from("invitee")
          .update({
            response,
          })
          .eq("event_id", body.eventId)
          .in("contact_id", contactIds)
      );

      await respond(
        calendarConfig,
        credentials,
        event.calendar.provider_id,
        event.provider_id,
        response,
        body.email,
        body.isOrganizer
      );
      return new Response(null, {
        status: 200,
      });
    }
    default:
      return new Response("Unsupported method", { status: 405 });
  }
};
