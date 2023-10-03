import { logDevReady } from "@remix-run/cloudflare";
import { createPagesFunctionHandler } from "@remix-run/cloudflare-pages";
import * as build from "@remix-run/dev/server-build";

import type { Environment } from "app/env.server";
import { init as sentryInit } from "app/sentry.server";
import { trackerInit } from "app/tracker.server";

if (process.env.NODE_ENV === "development") {
  logDevReady(build);
}

export type Context = EventContext<Environment, string, unknown>;

export async function onRequest(context: Context) {
  const sentry = sentryInit(context, context.request);
  const tracker = trackerInit(context, context.request);

  const handleRequest = createPagesFunctionHandler({
    build,
    getLoadContext: (context: Context) => ({ env: context.env, tracker }),
    mode: process.env.NODE_ENV,
  });

  const flush = () => {
    return Promise.all([
      sentry?.getClient()?.close?.(),
      tracker.flush().promise,
    ]);
  };

  let ret = undefined;
  try {
    ret = await handleRequest({
      ...context,
      env: {
        ...context.env,
        tracker,
        sentry,
      },
    });
  } catch (e) {
    context.waitUntil(flush());
    throw e;
  }
  context.waitUntil(flush());
  return ret;
}
