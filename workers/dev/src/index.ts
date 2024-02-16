import apiWorker from "@plotday/api";
import contactSyncWorker from "@plotday/contact-sync";
import type { ContactSyncRequest } from "@plotday/contact-sync";
import eventWorker from "@plotday/event-sync";
import syncWorker from "@plotday/sync";
import type { EventSyncRequest, SyncRequest } from "@plotday/sync";

interface Env {
  readonly ENV?: string;
  readonly RELEASE?: string;
  readonly PACKAGE?: string;

  readonly API_KEY: string;

  readonly SUPABASE_URL: string;
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

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    return await apiWorker.fetch(req, env);
  },

  async queue(batch: MessageBatch, env: Env): Promise<void> {
    switch (batch.queue) {
      case "plot-sync-development-queue":
        await syncWorker.queue(batch as MessageBatch<SyncRequest>, env);
        break;

      case "plot-event-development-queue":
        await eventWorker.queue(batch as MessageBatch<EventSyncRequest>, env);
        break;

      case "plot-contact-sync-development-queue":
        await contactSyncWorker.queue(
          batch as MessageBatch<ContactSyncRequest>,
          env
        );
        break;

      default:
        throw new Error(`Unknown queue ${batch.queue}`);
    }
  },

  async scheduled(event: ScheduledController, env: Env) {
    return await syncWorker.scheduled(event, env);
  },
};
