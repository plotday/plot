import { RewriteFrames } from "@sentry/integrations";
import { Toucan } from "toucan-js";

import type { Environment } from "app/env.server";

import { VERSION } from "./config";

export type Sentry = Toucan;

export const init = (context: { env: Environment }, request?: Request) => {
  const dsn = context.env.SENTRY_DSN;

  const options = {
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

  // @ts-ignore
  return new Toucan({
    dsn,
    ...options,
    request,
  });
};
