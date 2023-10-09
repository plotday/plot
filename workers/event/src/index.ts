import { Toucan } from "toucan-js";

import type { Event, EventResponse } from "@plotday/cal";
import { transform } from "@plotday/cal";
import type { Database } from "@plotday/db";
import { createClient, safeQuery } from "@plotday/db";
import type { EventSyncRequest } from "@plotday/worker-request";

type DbEvent = Database["public"]["Tables"]["event"]["Insert"];
type DbContact = Database["public"]["CompositeTypes"]["event_contact"];
type DbInvitee = Database["public"]["CompositeTypes"]["event_invitee"];
type EventInsert =
  Database["public"]["Functions"]["upsert_events"]["Args"]["_events"];

export interface Env {
  readonly ENV?: string;
  readonly RELEASE?: string;
  readonly PACKAGE?: string;

  readonly SUPABASE_URL: string;
  readonly SUPABASE_SERVICE_KEY: string;
  readonly SENTRY_DSN: string;
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
      at:
        event.startsAt && event.endsAt
          ? `[${event.startsAt.toISOString()},${event.endsAt.toISOString()})`
          : null,
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
      // The generated types are missing the null value
      response: (invitee.response || null) as NonNullable<EventResponse>,
      is_optional: !!invitee.isOptional,
    })),
  };
}

export default {
  async queue(batch: MessageBatch<EventSyncRequest>, env: Env): Promise<void> {
    const Sentry = new Toucan({
      dsn: env.SENTRY_DSN,
      environment: env.ENV,
      release: env.RELEASE,
      dist: env.PACKAGE,
    });

    let fullSyncComplete = [] as number[];
    try {
      const supabase = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_KEY);

      const inserts = batch.messages.reduce((inserts, message) => {
        try {
          if (message.body.fullSyncComplete) {
            fullSyncComplete.push(message.body.calendarId);
          }
          if (!message.body.rawEvent) return inserts;
          const event = transform(message.body.provider, message.body.rawEvent);
          // TODO: handle working locations
          if (eventType(event) !== "event") return inserts;
          const db = eventToDb(message.body.calendarId, event);
          return [
            ...inserts,
            {
              calendar_id: message.body.calendarId,
              raw_event: {
                calendar_id: message.body.calendarId,
                provider_id: message.body.rawEvent.id,
                event: message.body.rawEvent.data,
                sequence: message.body.sequence,
              },
              event: db.event,
              organizer: db.organizer as DbContact,
              invitees: db.invitees,
            },
          ];
        } catch (e) {
          console.error(e);
          if (message.body.rawEvent) {
            console.log(
              "Raw event",
              JSON.stringify(message.body.rawEvent.data)
            );
          }
          Sentry.withScope((scope) => {
            if (message.body.rawEvent) {
              scope.setExtra("event", message.body.rawEvent.data);
            }
            scope.setExtra("calendar-id", message.body.calendarId);
            Sentry.captureException(e);
          });
          return inserts;
        }
      }, [] as EventInsert);

      console.log(`Inserting ${inserts.length} events`);
      const result = safeQuery(
        await supabase.rpc("upsert_events", { _events: inserts })
      );
      for (const r of result ?? []) {
        if (!r.error) continue;
        console.error(`Failed to insert ${r.calendar_id}, ${r.provider_id}:`);
        console.error(r.error);
        Sentry.withScope((scope) => {
          scope.setExtra("calendar-id", r.calendar_id);
          scope.setExtra("provider-id", r.provider_id);
          Sentry.captureException(new Error(r.error));
        });
      }

      for (const calendarId of fullSyncComplete) {
        console.log(`Full sync ${calendarId} complete`);
        safeQuery(
          await supabase
            .from("calendar")
            .update({
              full_sync_at: new Date().toISOString(),
            })
            .eq("id", calendarId)
        );
      }
    } catch (e) {
      console.error(e);
      Sentry.captureException(e);
    }
  },
};
