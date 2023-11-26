import { useCallback, useEffect } from "react";

import { useFetcher } from "@remix-run/react";

import type { EventResponse } from "@plotday/cal";
import type { Event } from "@plotday/db";
import { parseDatetimeRange } from "@plotday/db";

import { getCalendarConfig, getCredentials, respond } from "app/cal";
import { safeQuery } from "app/db";
import { useEventOptimist } from "app/event";
import { privateAction } from "app/util";

type ResponseBody = {
  eventId: number;
  response: EventResponse;
  isOrganizer: boolean;
};

export function useEventResponder(event: Event) {
  const fetcher = useFetcher();
  const { setOverride, clearOverride } = useEventOptimist();
  const eventResponder = useCallback(
    (response: EventResponse) => {
      const body = {
        eventId: event.id,
        response,
        isOrganizer: event.isOrganizer,
      } as ResponseBody;
      fetcher.submit(body, {
        method: "put",
        action: "/api/event/response",
        encType: "application/json",
      });
    },
    [fetcher, event.id, event.isOrganizer]
  );
  const body = fetcher.json as ResponseBody;
  useEffect(() => {
    if (body) {
      setOverride(event.id, {
        response: body.response,
      });
      // return () => {
      //   clearOverride(event.id, ["attendance"]);
      // };
    }
  }, [body, setOverride, clearOverride, event.id]);
  return eventResponder;
}

export const action = privateAction(
  async ({ request, supabase, user, env, tracker }) => {
    switch (request.method) {
      case "PUT": {
        const body: ResponseBody = await request.json();

        const event = safeQuery(
          await supabase
            .from("event")
            .select("provider_id,at,calendar(provider_id,account(id,email))")
            .eq("id", body.eventId)
            .maybeSingle()
        );
        if (!event?.calendar?.account?.email)
          return new Response("Not found", { status: 404 });

        // TODO
        // const leadTime = Math.floor(
        //   (parseDatetimeRange(event.at as string, "UTC")[0].getTime() -
        //     Date.now()) /
        //     60000
        // );
        // if (body.response !== null) {
        //   tracker.meetingTriaged(user.id.toString(), {
        //     Choice: body.response,
        //     "Lead Time": leadTime,
        //   });
        // }

        let credentials = await getCredentials(
          supabase,
          event.calendar.account.id
        );

        // TODO
        // safeQuery(
        //   await supabase.from("response").upsert(
        //     {
        //       user_id: user.id,
        //       provider_id: event.provider_id,
        //       attendance: body.attendance,
        //     },
        //     { onConflict: "user_id,provider_id" }
        //   )
        // );

        safeQuery(
          await supabase
            .from("invitee")
            .update({
              response: body.response,
            })
            .eq("event_id", body.eventId)
            .eq("email", event.calendar.account.email)
        );

        await respond(
          getCalendarConfig(env),
          credentials,
          event.calendar.provider_id,
          event.provider_id,
          body.response,
          body.isOrganizer
        );
        return new Response(null, {
          status: 200,
        });
      }
      default:
        return new Response("Unsupported method", { status: 405 });
    }
  }
);
