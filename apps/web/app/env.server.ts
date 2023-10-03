import type { AppLoadContext } from "@remix-run/cloudflare";

import type { Queue } from "@cloudflare/workers-types";
import * as z from "zod";

import type { Tracker } from "@plotday/tracker";
import type { SyncRequest } from "@plotday/worker-request";

import type { Sentry } from "app/sentry.server";

type SyncQueue = Queue<SyncRequest>;

const environmentSchema = z.object({
  SUPABASE_URL: z.string().min(1),
  SUPABASE_ANON_KEY: z.string().min(1),
  SUPABASE_SERVICE_KEY: z.string().min(1),
  SENTRY_DSN: z.string(),

  GOOGLE_CLIENT_ID: z.string().min(1),
  GOOGLE_OAUTH_SECRET: z.string().min(1),
  MICROSOFT_CLIENT_ID: z.string().min(1),
  MICROSOFT_OAUTH_SECRET: z.string().min(1),

  AMPLITUDE_API_KEY: z.string().min(1),

  SYNC_QUEUE: z
    .custom<SyncQueue>((data) => typeof data === "object")
    .optional(),

  tracker: z.custom<Tracker>((data) => typeof data === "object"),
  sentry: z.custom<Sentry>((data) => typeof data === "object"),
});

export type Environment = z.infer<typeof environmentSchema>;

export const getEnv = (context: AppLoadContext) =>
  environmentSchema.parse(context.env);

export const getBrowserEnv = (context: AppLoadContext) => {
  const { SUPABASE_URL, SUPABASE_ANON_KEY, SENTRY_DSN } = getEnv(context);
  return { SUPABASE_URL, SUPABASE_ANON_KEY, SENTRY_DSN };
};
