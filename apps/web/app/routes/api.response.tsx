import { useCallback, useEffect } from "react";

import { useFetcher } from "@remix-run/react";

import type { EventResponse } from "@plotday/cal";
import type { Attendance, Event } from "@plotday/db";
import { parseDateRange } from "@plotday/db";

import { getCalendarConfig, getCredentials, respond } from "app/cal";
import { safeQuery } from "app/db";
import { useEventOptimist } from "app/event";
import { privateAction } from "app/util";

type ResponseBody = {
  eventId: number;
  attendance: Attendance;
  isOrganizer: boolean;
};

export function useEventResponder(event: Event) {
  const fetcher = useFetcher();
  const { setOverride, clearOverride } = useEventOptimist();
  const eventResponder = useCallback(
    (attendance: Attendance) => {
      const body = {
        eventId: event.id,
        attendance,
        isOrganizer: event.isOrganizer,
      } as ResponseBody;
      fetcher.submit(body, {
        method: "put",
        action: "/api/response",
        encType: "application/json",
      });
    },
    [fetcher, event.id, event.isOrganizer]
  );
  const body = fetcher.json as ResponseBody;
  useEffect(() => {
    if (body) {
      setOverride(event.id, {
        attendance: body.attendance,
      });
      // return () => {
      //   clearOverride(event.id, ["attendance"]);
      // };
    }
  }, [body, setOverride, clearOverride, event.id]);
  return eventResponder;
}

export const action = privateAction(
  async ({ request, supabase, user, env }) => {
    switch (request.method) {
      case "PUT": {
        const body: ResponseBody = await request.json();

        const event = safeQuery(
          await supabase
            .from("event")
            .select("provider_id,at,calendar(provider_id,account_id)")
            .eq("id", body.eventId)
            .maybeSingle()
        );
        if (!event?.calendar) return new Response("Not found", { status: 404 });

        const leadTime = Math.floor(
          (parseDateRange(event.at as string, "UTC")[0].getTime() -
            Date.now()) /
            60000
        );
        if (body.attendance !== null) {
          env.tracker.meetingTriaged(user.id.toString(), {
            Choice: body.attendance,
            "Lead Time": leadTime,
          });
        }

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
          getCalendarConfig(env),
          credentials,
          event.calendar.provider_id,
          event.provider_id,
          response,
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
