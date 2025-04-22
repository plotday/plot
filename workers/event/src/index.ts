import * as Sentry from "@sentry/cloudflare";

import type { Event } from "@plotday/cal";
import { transform } from "@plotday/cal";
import type { Database, SupabaseClient } from "@plotday/db";
import { calendarToDb, createClient, safeQuery } from "@plotday/db";
import type { EventSyncRequest } from "@plotday/sync";

type DbRawEvent = Database["public"]["Tables"]["raw_event"]["Insert"];
type DbEvent = Database["public"]["Tables"]["event"]["Insert"];
type DbSeries = Database["public"]["Tables"]["series"]["Insert"];

export interface Env {
  readonly SUPABASE_URL: string;
  readonly SUPABASE_SERVICE_KEY: string;
  readonly SENTRY_DSN: string;

  readonly AI: Ai;
}

function eventType(event: Event): "event" | "working_location" {
  let availability = event.availability;
  if (availability === "location") {
    return "working_location";
  }
  return "event";
}

async function insertRawEvents(
  batch: MessageBatch<EventSyncRequest>,
  supabase: SupabaseClient
) {
  const rawEvents = batch.messages.reduce((rawEvents, message) => {
    if (!message.body.rawEvent) return rawEvents;
    return [
      ...rawEvents,
      {
        calendar_id: message.body.calendarId,
        provider_id: message.body.rawEvent.id,
        event: message.body.rawEvent.data,
      },
    ];
  }, [] as DbRawEvent[]);
  console.log(`Inserting ${rawEvents.length} raw events`);
  safeQuery(
    await supabase
      .from("raw_event")
      .upsert(rawEvents, { onConflict: "calendar_id, provider_id" })
  );
}

async function insertContacts(
  events: { event: Event; calendarId: number }[],
  supabase: SupabaseClient
) {
  const contacts = Object.values(
    events.reduce((contacts, event) => {
      const organizer = event.event.organizer;
      let all = event.event.invitees;
      if (organizer) all = [...all, organizer];
      for (const invitee of all) {
        const id = `${event.calendarId}:${invitee.email}`;
        contacts[id] = {
          ...contacts[id],
          calendar_id: event.calendarId,
          email: invitee.email,
          ...(invitee.name && { name: invitee.name }),
          ...(invitee.avatar && { avatar_url: invitee.avatar }),
        };
      }
      return contacts;
    }, {} as Record<string, Database["public"]["Functions"]["upsert_contacts"]["Args"]["_contacts"][number]>)
  );
  console.log(`Inserting ${contacts.length} contacts`);
  safeQuery(
    await supabase.rpc("upsert_contacts", {
      _contacts: contacts,
    })
  );
}

async function generateEmbeddings(env: Env, text: string[]) {
  console.log(`Generating ${text.length} embeddings`);
  const embeddings = await env.AI.run("@cf/baai/bge-small-en-v1.5", { text });
  return embeddings;
}

export default Sentry.withSentry(
  (env) => ({
    dsn: env.SENTRY_DSN,
    release: RELEASE,
    dist: PACKAGE,
    environment: ENV,
  }),
  {
    async queue(unknownBatch, env): Promise<void> {
      const batch = unknownBatch as MessageBatch<EventSyncRequest>;
      let backgroundJobs = [] as Promise<any>[];

      try {
        const supabase = createClient(
          env.SUPABASE_URL,
          env.SUPABASE_SERVICE_KEY
        );

        backgroundJobs.push(insertRawEvents(batch, supabase));

        const events = batch.messages.reduce((events, message) => {
          try {
            if (!message.body.rawEvent) return events;
            const event = transform(
              message.body.provider,
              message.body.rawEvent,
              message.body.accountEmail
            );
            // TODO: handle working locations
            if (eventType(event) !== "event") return events;
            return [
              ...events,
              {
                event,
                calendarId: message.body.calendarId,
                userId: message.body.userId,
                sequence: message.body.sequence,
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
            return events;
          }
        }, [] as { event: Event; userId: string; calendarId: number; sequence: number }[]);

        backgroundJobs.push(insertContacts(events, supabase));

        const eventChanges = events.reduce(
          (eventChanges, event) => {
            try {
              // TODO: handle working locations
              if (
                eventType(event.event) !== "event" ||
                event.event.availability === "location"
              )
                return eventChanges;
              if (event.event.status === "cancelled") {
                return {
                  ...eventChanges,
                  cancelations: [
                    ...eventChanges.cancelations,
                    {
                      calendar_id: event.calendarId,
                      provider_id: event.event.id,
                    },
                  ],
                };
              }
              const db: DbEvent = calendarToDb(
                event.userId,
                event.event,
                event.calendarId,
                event.sequence
              );
              const key = `${event.calendarId}:${event.event.id}`;
              return {
                ...eventChanges,
                inserts: {
                  ...eventChanges.inserts,
                  [key]: {
                    event: event.event,
                    db: {
                      ...eventChanges.inserts[key]?.db,
                      ...db,
                    },
                  },
                },
              };
            } catch (e) {
              console.error(e);
              Sentry.withScope((scope) => {
                scope.setExtra("calendar-id", event.calendarId);
                scope.setExtra("provider-id", event.event.id);
                Sentry.captureException(e);
              });
              return eventChanges;
            }
          },
          {
            inserts: {} as Record<string, { event: Event; db: DbEvent }>,
            cancelations: [] as { calendar_id: number; provider_id: string }[],
          }
        );
        let eventInserts = Object.values(eventChanges.inserts);

        console.log(`Inserting ${eventInserts.length} events`);
        // It's critical that we have no duplicate calendar_id, provider_id
        // entries, as they will cause the upsert to fail with
        // "ON CONFLICT DO UPDATE command cannot affect row a second time"
        const insertedEvents =
          safeQuery(
            await supabase
              .from("event")
              .upsert(
                eventInserts.map((i) => i.db),
                {
                  onConflict: "calendar_id, provider_id",
                }
              )
              .select("id")
          )?.map((event, index) => ({
            id: event.id,
            event: eventInserts[index].event,
          })) ?? [];

        let series: (DbSeries & { text?: string })[] = Object.values(
          Object.fromEntries(
            eventInserts.map((insert) => [
              insert.event.series ?? insert.event.id,
              {
                user_id: insert.db.user_id,
                series: insert.event.series ?? insert.event.id,
                text: insert.event.name ?? "Untitled",
                invitees: insert.event.invitees.map((invitee) => invitee.email),
              },
            ])
          )
        );
        const embeddings = await generateEmbeddings(
          env,
          series.map((i) => i.text!)
        );
        series = series.map((item, i) => {
          const { text: _, ...rest } = item;
          const embedding = `[${embeddings.data[i].join(",")}]`;
          return {
            ...rest,
            embedding,
          };
        });
        safeQuery(
          await supabase
            .from("series")
            .upsert(series, { onConflict: "user_id, series" })
        );

        if (eventChanges.cancelations.length > 0) {
          console.log(`Cancelling ${eventChanges.cancelations.length} events`);
          backgroundJobs.push(
            (async () => {
              safeQuery(
                await supabase.rpc("cancel_events", {
                  _events: eventChanges.cancelations,
                })
              );
            })()
          );
        }

        const invitees = insertedEvents
          .map(({ id, event }) =>
            event.invitees.map((invitee) => ({
              event_id: id,
              email: invitee.email,
              response: (invitee.response ??
                null) as any as Database["public"]["Enums"]["event_response"],
              is_optional: !!invitee.isOptional,
            }))
          )
          .flat();
        console.log(`Inserting ${invitees.length} invitees`);
        safeQuery(
          await supabase.rpc("upsert_invitees", {
            _event_ids: insertedEvents.map((i) => i.id),
            _invitees: invitees,
          })
        );

        for (const message of batch.messages) {
          const syncType = message.body.complete;
          if (!syncType) continue;
          console.log(`${syncType} sync complete (${message.body.calendarId})`);
          backgroundJobs.push(
            (async () => {
              safeQuery(
                await supabase
                  .from("event")
                  .delete()
                  .eq("calendar_id", message.body.calendarId)
                  .lt("sequence", message.body.sequence)
              );
            })()
          );
          backgroundJobs.push(
            (async () => {
              safeQuery(
                await supabase
                  .from("calendar")
                  .update({
                    ready: true,
                    ...(syncType === "full" && {
                      full_sync_at: new Date().toISOString(),
                    }),
                  })
                  .eq("id", message.body.calendarId)
              );
            })()
          );
        }
      } catch (e) {
        console.error(e);
        Sentry.captureException(e);
        throw e;
      } finally {
        const backgroundErrors = (await Promise.allSettled(backgroundJobs))
          .map((result) =>
            result.status === "rejected" ? result.reason : null
          )
          .filter((result) => result);
        backgroundErrors.forEach((error) => Sentry.captureException(error));
        if (backgroundErrors.length === 1) {
          throw new Error(backgroundErrors[0]);
        } else if (backgroundErrors.length > 1) {
          throw new Error("Background jobs failed", {
            cause: backgroundErrors,
          });
        }
      }
    },
  }
);
