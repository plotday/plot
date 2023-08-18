import type { SupabaseClient } from "@supabase/supabase-js";

import { Toucan } from "toucan-js";

import { Event, createClient, safeQuery } from "@plotday/db";
import type { EventLabelRequest } from "@plotday/worker-request";

export interface Env {
  readonly ENV?: string;
  readonly RELEASE?: string;
  readonly PACKAGE?: string;

  readonly SUPABASE_URL: string;
  readonly SUPABASE_SERVICE_KEY: string;
  readonly SENTRY_DSN: string;

  readonly QUEUE: Queue<EventLabelRequest>;
}

async function labelEvent(
  supabase: SupabaseClient,
  labels: Record<string, number>,
  eventId: number
) {
  const dbEvent = await Event.Get(supabase, eventId);
  if (!dbEvent) {
    throw Error(`Event ${eventId} not found`);
  }
  // Timezone shouldn't affect labels
  const event = new Event(dbEvent, "America/New_York");
  const eventLabels = event.guessLabels();
  const labelErrors: string[] = [];
  const labelsToAdd = [];
  for (const label of eventLabels) {
    if (!(label in labels)) {
      labelErrors.push(label);
    } else {
      labelsToAdd.push({
        event_id: eventId,
        series: null,
        label_id: labels[label],
        priority: 10,
      });
    }
  }

  if (labelsToAdd.length > 0) {
    safeQuery(
      await supabase
        .from("event_label")
        .upsert(labelsToAdd, { onConflict: "event_id,series,label_id" })
    );
  }
  if (labelErrors.length) {
    throw Error(`Labels not found: ${labelErrors.join(", ")}`);
  }
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
      | EventLabelRequest
      | MessageSendRequest<EventLabelRequest>[];
    if (body instanceof Array) {
      await env.QUEUE.sendBatch(body);
    } else {
      await env.QUEUE.send(body);
    }

    return new Response("Labeling queued");
  },

  async queue(batch: MessageBatch<EventLabelRequest>, env: Env): Promise<void> {
    const Sentry = new Toucan({
      dsn: env.SENTRY_DSN,
      environment: env.ENV,
      release: env.RELEASE,
      dist: env.PACKAGE,
    });

    try {
      const supabase = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_KEY);

      const labels = (
        safeQuery(
          await supabase
            .from("label")
            .select("id,name")
            .filter("user_id", "is", null)
        ) || []
      ).reduce((acc, label) => {
        acc[label.name] = label.id;
        return acc;
      }, {} as Record<string, number>);

      let messageNum = 1;
      for (let message of batch.messages) {
        try {
          console.log(
            `Processing ${messageNum} of ${batch.messages.length} (${message.body.eventId})`
          );
          await labelEvent(supabase, labels, message.body.eventId);
          message.ack();
        } catch (e) {
          console.error(e);
          Sentry.withScope((scope) => {
            scope.setExtra("event-id", message.body.eventId);
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
