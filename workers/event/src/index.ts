import { Toucan } from "toucan-js";

import type { Event, EventResponse } from "@plotday/cal";
import { transform } from "@plotday/cal";
import type { Database } from "@plotday/db";
import { createClient, safeQuery } from "@plotday/db";
import type { EventSyncRequest } from "@plotday/worker-request";

type DbEvent = Database["public"]["Tables"]["event"]["Insert"];
type DbContact = Database["public"]["CompositeTypes"]["event_contact"];
type DbInvitee = Database["public"]["CompositeTypes"]["event_invitee"];

export interface Env {
  readonly ENV?: string;
  readonly RELEASE?: string;

  readonly SUPABASE_URL: string;
  readonly SUPABASE_SERVICE_KEY: string;
  readonly SENTRY_DSN: string;

  readonly QUEUE: Queue<EventSyncRequest>;
}

function eventType(event: Event): "event" | "working_location" {
  let availability = event.availability;
  if (availability === "location") {
    return "working_location";
  }
  return "event";
}

function eventToDb(
  calendarId: number,
  event: Event
): { event: DbEvent; organizer: DbContact | null; invitees: DbInvitee[] } {
  let availability = event.availability;
  if (availability === "location") {
    throw new Error("Location event passed to eventToDb");
  }
  return {
    event: {
      calendar_id: calendarId,
      provider_id: event.id,
      series: event.series,
      name: event.name,
      status: event.status,
      description: event.description,
      summary: event.summary,
      provider_link: event.providerLink,
      visibility: event.visibility,
      availability,
      conferencing_url: event.conferencing?.url,
      created_at: event.createdAt?.toISOString(),
      at: `[${event.startsAt.toISOString()},${event.endsAt.toISOString()})`,
    },
    organizer: event.organizer
      ? {
          name: event.organizer.name as string,
          email: event.organizer.email as string,
        }
      : null,
    invitees: event.invitees.map((invitee) => ({
      contact: {
        email: invitee.email as string,
        name: invitee.name as string as string,
      },
      response: invitee.response as EventResponse,
      is_optional: !!invitee.isOptional,
    })),
  };
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    if (req.method !== "POST") {
      return new Response("Method Not Allowed", { status: 405 });
    }
    if (env.ENV !== "development") {
      return new Response("Forbidden", { status: 403 });
    }
    const body = (await req.json()) as
      | EventSyncRequest
      | MessageSendRequest<EventSyncRequest>[];
    if (body instanceof Array) {
      await env.QUEUE.sendBatch(body);
    } else {
      await env.QUEUE.send(body);
    }

    return new Response("Sync queued");
  },

  async queue(batch: MessageBatch<EventSyncRequest>, env: Env): Promise<void> {
    const Sentry = new Toucan({
      dsn: env.SENTRY_DSN,
      environment: env.ENV,
      release: env.RELEASE,
      dist: "event-sync",
    });

    try {
      const supabase = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_KEY);

      let messageNum = 1;
      for (let message of batch.messages) {
        try {
          console.log(
            `Processing ${messageNum} of ${batch.messages.length} (${message.body.calendarId})`
          );
          const event = transform(message.body.provider, message.body.rawEvent);
          // TODO: handle working locations
          if (eventType(event) !== "event") continue;
          const db = eventToDb(message.body.calendarId, event);
          safeQuery(
            await supabase.rpc("upsert_event", {
              _calendar_id: message.body.calendarId,
              _raw_event: {
                calendar_id: message.body.calendarId,
                provider_id: message.body.rawEvent.id,
                event: message.body.rawEvent.data,
                sequence: message.body.sequence,
              },
              _event: db.event,
              _organizer: db.organizer as DbContact,
              _invitees: db.invitees,
            })
          );
          message.ack();
        } catch (e) {
          console.error(e);
          Sentry.withScope((scope) => {
            scope.setExtra("event", message.body.rawEvent.data);
            scope.setExtra("calendar-id", message.body.calendarId);
            Sentry.captureException(e);
          });
          message.retry();
        }
        messageNum += 1;
      }
    } catch (e) {
      console.error(e);
      Sentry.captureException(e);
    }
  },
};
