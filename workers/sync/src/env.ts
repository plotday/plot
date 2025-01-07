import type { ContactSyncRequest } from "@plotday/contact-sync";

import type { EventSyncRequest, SyncRequest } from "./";

export interface Env {
  readonly API_KEY: string;

  readonly SUPABASE_URL: string;
  readonly SUPABASE_ANON_KEY: string;
  readonly SUPABASE_SERVICE_KEY: string;
  readonly SENTRY_DSN: string;
  readonly GOOGLE_CLIENT_ID: string;
  readonly GOOGLE_OAUTH_SECRET: string;
  readonly MICROSOFT_CLIENT_ID: string;
  readonly MICROSOFT_OAUTH_SECRET: string;
  readonly CALENDAR_WEBHOOK_URL: string;

  readonly SYNC_QUEUE: Queue<SyncRequest>;
  readonly EVENT_QUEUE: Queue<EventSyncRequest>;
  readonly CONTACT_SYNC_QUEUE: Queue<ContactSyncRequest>;
}
