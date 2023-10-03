import { useCallback, useEffect } from "react";

import { useFetcher } from "@remix-run/react";

import { parseDateRange } from "@plotday/db";
import type { Event } from "@plotday/db";

import { safeQuery } from "app/db";
import { useEventOptimist } from "app/event";
import { privateAction } from "app/util";

type ApiBody = {
  eventId: number;
  providerId: string;
  ready?: boolean;
  reviewed?: boolean;
};

export function useEventReadyResponder(event: Event) {
  const fetcher = useFetcher();
  const { setOverride, clearOverride } = useEventOptimist();
  const cb = useCallback(
    (ready?: boolean, reviewed?: boolean) => {
      const body = {
        eventId: event.id,
        providerId: event.providerId,
        ready,
        reviewed,
      } as ApiBody;
      fetcher.submit(body, {
        method: "patch",
        action: "/api/event/ready",
        encType: "application/json",
      });
    },
    [fetcher, event.id, event.providerId]
  );
  const body = fetcher.json as ApiBody;
  useEffect(() => {
    if (body) {
      const ready = body.ready ? new Date().toISOString() : null;
      const reviewed = body.reviewed ? new Date().toISOString() : null;
      setOverride(event.id, {
        ...(ready === undefined ? {} : { ready }),
        ...(reviewed === undefined ? {} : { reviewed }),
      });
      // return () => {
      //   clearOverride(event.id, ["attendance"]);
      // };
    }
  }, [body, setOverride, clearOverride, event.id]);
  return cb;
}

export const action = privateAction(
  async ({ request, user, supabase, env, response }) => {
    switch (request.method) {
      case "PATCH": {
        const body: ApiBody = await request.json();
        safeQuery(
          await supabase
            .from("response")
            .upsert(
              {
                user_id: user.id,
                provider_id: body.providerId,
                ...(body.ready !== undefined && {
                  ready: body.ready ? new Date().toISOString() : null,
                }),
                ...(body.reviewed !== undefined && {
                  reviewed: body.reviewed ? new Date().toISOString() : null,
                }),
              },
              { onConflict: "user_id,provider_id" }
            )
            .eq("user_id", user.id)
            .eq("provider_id", body.providerId)
        );

        const event = safeQuery(
          await supabase
            .from("event")
            .select("provider_id,at")
            .eq("id", body.eventId)
            .maybeSingle()
        );
        if (event) {
          const leadTime = Math.floor(
            (parseDateRange(event.at as string, "UTC")[0].getTime() -
              Date.now()) /
              60000
          );
          if (body.ready === true) {
            env.tracker.meetingPrepped(user.id.toString(), {
              "Lead Time": leadTime,
            });
          }
          if (body.reviewed === true) {
            env.tracker.meetingReviewed(user.id.toString(), {
              "Lead Time": leadTime,
            });
          }
        }

        return new Response(null, {
          headers: response.headers,
          status: 200,
        });
      }

      default:
        return new Response("Unsupported method", { status: 405 });
    }
  }
);
