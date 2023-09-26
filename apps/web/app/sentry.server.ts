import type { AppLoadContext } from "@remix-run/cloudflare";

import { RewriteFrames } from "@sentry/integrations";
import { Toucan } from "toucan-js";

import { VERSION } from "./config";

export let Sentry: Toucan | undefined;

export const SentryServerOptions = {
  requestDataOptions: {
    allowedSearchParams: true,
    allowedIps: true,
  },
  environment: process.env.NODE_ENV,
  release: VERSION,
  dist: "server",
  integrations: [
    new RewriteFrames({
      iteratee: (frame) => {
        if (!frame.filename) return frame;
        frame.filename = "index.js";
        frame.abs_path = "/index.js";
        return frame;
      },
    }),
  ],
};

export const SentryServerInit = (
  context: AppLoadContext,
  request?: Request
) => {
  if (Sentry) return;
  const dsn = (context.env as any)?.SENTRY_DSN;
  if (!dsn) return;
  // @ts-ignore
  Sentry = new Toucan({
    dsn,
    ...SentryServerOptions,
    request,
  });
};
