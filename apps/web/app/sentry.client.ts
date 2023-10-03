import { useEffect } from "react";

import { useLocation, useMatches } from "@remix-run/react";

import * as ClientSentry from "@sentry/remix";
import { captureRemixErrorBoundaryError as clientCaptureRemixErrorBoundaryError } from "@sentry/remix";

import { VERSION } from "./config";

export let Sentry: typeof ClientSentry | undefined;

export const init = (
  dsn: string,
  user?: { id: number; email: string | null } | null
) => {
  if (Sentry) return;
  Sentry = ClientSentry;
  // https://docs.sentry.io/platforms/javascript/guides/remix/
  ClientSentry.init({
    dsn,
    environment: process.env.NODE_ENV,
    release: VERSION,
    dist: "browser",
    integrations: [
      new ClientSentry.BrowserTracing({
        routingInstrumentation: ClientSentry.remixRouterInstrumentation(
          useEffect,
          useLocation,
          useMatches
        ),
      }),
      // Replay is only available in the client
      new ClientSentry.Replay(),
    ],

    // Set tracesSampleRate to 1.0 to capture 100%
    // of transactions for performance monitoring.
    // We recommend adjusting this value in production
    tracesSampleRate: 1.0,

    // Capture Replay for 10% of all sessions,
    // plus for 100% of sessions with an error
    replaysSessionSampleRate: 0.1,
    replaysOnErrorSampleRate: 1.0,
  });
  if (user?.id || user?.email) {
    ClientSentry.setUser({
      id: user?.id?.toString?.(),
      email: user?.email || undefined,
    });
  }
};

export const captureRemixErrorBoundaryError = (error: any) => {
  if (Sentry === ClientSentry) {
    clientCaptureRemixErrorBoundaryError(error);
  } else {
    Sentry?.captureException?.(error);
  }
};
