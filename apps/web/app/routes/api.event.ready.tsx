import { useCallback } from "react";

import type { ActionArgs } from "@remix-run/cloudflare";
import { useFetcher } from "@remix-run/react";

import { getUser } from "app/auth";
import { createServerClient, safeQuery } from "app/db";

type ApiBody = {
  providerId: string;
  ready?: boolean;
  reviewed?: boolean;
};

export function useEventReadyResponder() {
  const fetcher = useFetcher();
  return useCallback(
    (providerId: string, ready?: boolean, reviewed?: boolean) => {
      const body = {
        providerId,
        ready,
        reviewed,
      } as ApiBody;
      fetcher.submit(body, {
        method: "patch",
        action: "/api/event/ready",
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

  switch (request.method) {
    case "PATCH": {
      const body: ApiBody = await request.json();
      console.log("body", user.id, body);
      const event = safeQuery(
        await supabase
          .from("response")
          .upsert(
            {
              user_id: user.id,
              provider_id: body.providerId,
              ...(body.ready !== undefined && { ready: body.ready }),
              ...(body.reviewed !== undefined && { reviewed: body.reviewed }),
            },
            { onConflict: "user_id,provider_id" }
          )
          .eq("provider_id", body.providerId)
          .select()
      );
      return new Response(JSON.stringify(event), {
        headers: response.headers,
        status: 200,
      });
    }

    default:
      return new Response("Unsupported method", { status: 405 });
  }
};
