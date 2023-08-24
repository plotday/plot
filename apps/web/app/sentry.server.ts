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
        return frame;
      },
    }),
  ],
};

export const SentryServerInit = (dsn: string, request?: Request) => {
  if (Sentry) return;
  // @ts-ignore
  Sentry = new Toucan({
    dsn,
    ...SentryServerOptions,
    request,
  });
};
