import * as Sentry from "@sentry/cloudflare";

import type { CalendarConfig, OutlookChangeNotification } from "@plotday/cal";
import { deleteWatch, watch } from "@plotday/cal";
import type { Database } from "@plotday/db";
import {
  createClient,
  getCredentials,
  safeQuery,
  saveCredentials,
} from "@plotday/db";
import type { SyncRequest } from "@plotday/sync";

type Calendar = Database["public"]["Tables"]["calendar"]["Row"];

export interface Env {
  readonly SUPABASE_URL: string;
  readonly SUPABASE_SERVICE_KEY: string;
  readonly SENTRY_DSN: string;
  readonly GOOGLE_CLIENT_ID: string;
  readonly GOOGLE_OAUTH_SECRET: string;
  readonly MICROSOFT_CLIENT_ID: string;
  readonly MICROSOFT_OAUTH_SECRET: string;

  readonly SYNC_QUEUE: Queue<SyncRequest>;
}

function handleException(e: any, extra?: Record<string, any>) {
  if (e instanceof Response) throw e;

  if (e instanceof Error && e.message) {
    console.error(e.message);
  } else {
    console.error("Unknown error");
  }
  Sentry?.withScope?.((scope) => {
    if (extra) {
      for (const [key, value] of Object.entries(extra)) {
        scope.setExtra?.(key, value);
      }
    }
    Sentry?.captureException?.(e);
  });
  return new Response(JSON.stringify(e), {
    status: 500,
    headers: {
      "content-type": "application/json;charset=UTF-8",
    },
  });
}

function getCalendarConfig(env: Env): CalendarConfig {
  return {
    googleClientId: env.GOOGLE_CLIENT_ID,
    googleOauthSecret: env.GOOGLE_OAUTH_SECRET,
    outlookClientId: env.MICROSOFT_CLIENT_ID,
    outlookOauthSecret: env.MICROSOFT_OAUTH_SECRET,
  };
}

export default Sentry.withSentry(
  (env) => ({
    dsn: env.SENTRY_DSN,
    environment: ENV,
    release: RELEASE,
    dist: PACKAGE,
    enabled: ENV !== "development",
  }),
  {
    async fetch(request, env) {
      try {
        const url = new URL(request.url);
        switch (url.pathname) {
          case "/google":
            return await handleGoogle(request, env);
          case "/outlook":
            return await handleOutlook(request, env);
          default:
            return new Response(JSON.stringify("No matching path"), {
              status: 404,
            });
        }
      } catch (e) {
        return handleException(e);
      }
    },

    async scheduled(_event, env) {
      await renewWatches(env);
    },
  } satisfies ExportedHandler<Env>
);

async function queueSync(
  env: Env,
  watchId: string,
  watchSecret: string,
  resourceId?: string
) {
  const calendarConfig = getCalendarConfig(env);

  const supabase = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_KEY);
  const calendar = safeQuery(
    await supabase
      .from("calendar")
      .select("*,account(user_id)")
      .eq("watch_id", watchId)
      .maybeSingle()
  );
  if (!calendar) throw new Error(`Calendar for watch ${watchId} not found`);

  const accountId = calendar.account_id;
  const userId = calendar.account!.user_id;
  let credentials = await getCredentials(supabase, accountId);

  if (watchId !== calendar.watch_id) {
    ({ credentials } = await deleteWatch(
      calendarConfig,
      credentials,
      watchId,
      resourceId
    ));
    await saveCredentials(supabase, userId, credentials, true);
    return;
  }

  if (watchSecret !== calendar.watch_secret) {
    return;
  }

  await env.SYNC_QUEUE.send({
    calendarId: calendar.id,
    syncType: "incremental",
  });

  return;
}

async function handleGoogle(request: Request, env: Env) {
  const watchId = request.headers.get("X-Goog-Channel-ID");
  if (!watchId) {
    throw new Error("Missing X-Goog-Channel-ID");
  }
  const channelToken = request.headers.get("X-Goog-Channel-Token");
  if (!channelToken) {
    throw new Error("Missing X-Goog-Channel-Token");
  }
  const resourceId = request.headers.get("X-Goog-Resource-URI");
  if (!resourceId) {
    throw new Error("Missing X-Goog-Resource-URI");
  }

  const params = new URLSearchParams(channelToken);
  const watchSecret = params.get("secret");
  if (!watchSecret) {
    throw new Error("Missing client secret");
  }

  await queueSync(env, watchId, watchSecret, resourceId);
  return new Response(null, {
    status: 200,
  });
}

async function renewWatch(env: Env, userId: string, calendar: Calendar) {
  const supabase = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_KEY);
  const accountId = calendar.account_id;
  let credentials = await getCredentials(supabase, accountId);

  console.log(`Renewing watch for ${calendar.id}`);

  const calendarConfig = getCalendarConfig(env);
  let state;
  ({ state, credentials } = await watch(
    calendarConfig,
    credentials,
    calendar.provider_id,
    calendar.watch_id && calendar.watch_secret
      ? {
          watchId: calendar.watch_id,
          watchSecret: calendar.watch_secret,
        }
      : undefined
  ));
  await saveCredentials(supabase, userId, credentials, true);

  safeQuery(
    await supabase
      .from("calendar")
      .update({
        watch_id: state.watchId,
        provider_id: state.calendarId,
        watch_secret: state.secret,
        watch_expires_at: state.expiry.toISOString(),
      })
      .eq("id", calendar.id)
  );
  return;
}

async function renewWatchById(env: Env, watchId: string) {
  const supabase = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_KEY);
  const calendar = safeQuery(
    await supabase
      .from("calendar")
      .select("*, account(user_id)")
      .eq("watch_id", watchId)
      .maybeSingle()
  );
  if (!calendar) throw new Error(`Calendar for watch ${watchId} not found`);
  await renewWatch(env, calendar.account!.user_id, calendar);
}

async function handleOutlook(request: Request, env: Env) {
  const url = new URL(request.url);

  const validationToken = url.searchParams.get("validationToken");
  if (validationToken) {
    console.log("Returning validation token", validationToken);
    return new Response(validationToken, {
      status: 200,
      headers: {
        "content-type": "text/plain",
      },
    });
  }

  const json = await request.json();
  if (!json || typeof json !== "object" || !("value" in json)) {
    return new Response("Missing data", {
      status: 400,
    });
  }

  const notifications = json.value as OutlookChangeNotification[];
  let response = new Response(null, {
    status: 200,
  });
  for (const notification of notifications) {
    try {
      const watchId = notification.subscriptionId;
      const watchSecret = notification.clientState;
      if (!watchId || !watchSecret) {
        throw new Error("Missing watch ID or secret");
      }

      if (notification.changeType) {
        await queueSync(env, watchId, watchSecret);
      } else if (notification.lifecycleEvent) {
        switch (notification.lifecycleEvent) {
          case "reauthorizationRequired":
            await renewWatchById(env, watchId);
            break;
          case "subscriptionRemoved":
            await renewWatchById(env, watchId);
            break;
          case "missed":
            await queueSync(env, watchId, watchSecret);
            break;
        }
      } else {
        throw new Error("Unknown notification type");
      }
    } catch (e) {
      response = handleException(e, { notification });
    }
  }
  return response;
}

async function renewWatches(env: Env) {
  const supabase = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_KEY);
  const calendars =
    safeQuery(
      await supabase
        .from("calendar")
        .select("*, account(user_id)")
        .lte(
          "watch_expires_at",
          new Date(Date.now() + 60 * 60 * 1000).toISOString()
        )
    ) || [];
  for (const calendar of calendars) {
    try {
      await renewWatch(env, calendar.account!.user_id, calendar);
    } catch (e) {
      handleException(e, { calendar_id: calendar.id });
    }
  }
}
