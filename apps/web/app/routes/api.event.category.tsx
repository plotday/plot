import { useCallback } from "react";

import { useFetcher } from "@remix-run/react";

import type { Event } from "@plotday/db";
import { nameToPath } from "@plotday/db";

import { safeQuery } from "app/db";
import { privateAction } from "app/util";

type UpdateBody = {
  id: number;
  categoryId?: number;
  categoryName?: string;
  categoryRole?: string;
};

export function useEventCategorizer(event: Event) {
  const fetcher = useFetcher();
  const id = event.id;
  return useCallback(
    (params: { id?: number; role?: string; name?: string }) => {
      const body = {
        id,
        categoryId: params.id,
        categoryRole: params.role,
        categoryName: params.name,
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

export const action = privateAction(
  async ({ request, response, user, supabase }) => {
    switch (request.method) {
      case "PUT": {
        const body: UpdateBody = await request.json();
        let categoryId = body.categoryId;
        if (!categoryId) {
          if (!body.categoryName || !body.categoryRole) {
            return new Response(
              "Missing categoryId, categoryName, and/or categoryRole",
              { status: 400 }
            );
          }
          const category = nameToPath(body.categoryName);
          const path = `${body.categoryRole}.${category}`;
          ({ id: categoryId } = safeQuery(
            await supabase
              .from("category")
              .upsert(
                {
                  user_id: user.id,
                  name: body.categoryName as string,
                  path,
                },
                { ignoreDuplicates: true }
              )
              .select()
              .single()
          ));
        }
        const event = safeQuery(
          await supabase
            .from("event_x")
            .select()
            .eq("id", body.id)
            .maybeSingle()
        );
        if (!event?.user_id) return new Response("Not found", { status: 404 });
        safeQuery(
          await supabase.from("event_rule").upsert([
            {
              user_id: event.user_id,
              series: event.series,
              category_id: categoryId,
            },
            {
              user_id: event.user_id,
              name: event.name,
              invitees: event.invitees,
              category_id: categoryId,
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
  }
);
