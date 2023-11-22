import { useCallback } from "react";

import { useFetcher } from "@remix-run/react";

import type { Event } from "@plotday/db";

import { safeQuery } from "app/db";
import { privateAction } from "app/util";

type UpdateBody = {
  id: number;
  categoryId: number;
};

export function useEventCategorizer(event: Event) {
  const fetcher = useFetcher();
  const id = event.id;
  return useCallback(
    (categoryId: number) => {
      const body = {
        id,
        categoryId,
      } as UpdateBody;
      fetcher.submit(body, {
        method: "put",
        action: "/api/event/category",
        encType: "application/json",
      });
    },
    [fetcher, id]
  );
}

export const action = privateAction(async ({ request, response, supabase }) => {
  switch (request.method) {
    case "PUT": {
      const body: UpdateBody = await request.json();
      const event = safeQuery(
        await supabase.from("event_x").select().eq("id", body.id).maybeSingle()
      );
      if (!event?.user_id) return new Response("Not found", { status: 404 });
      safeQuery(
        await supabase.from("event_rule").upsert([
          {
            user_id: event.user_id,
            series: event.series,
            category_id: body.categoryId,
          },
          {
            user_id: event.user_id,
            name: event.name,
            invitees: event.invitees,
            category_id: body.categoryId,
          },
        ])
      );
      return new Response(null, {
        headers: response.headers,
        status: 200,
      });
    }
    default:
      return new Response("Unsupported method", { status: 405 });
  }
});
