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
}

async function labelEvent(supabase: SupabaseClient, eventId: number) {
  const dbEvent = await Event.Get(supabase, eventId);
  if (!dbEvent) {
    throw Error(`Event ${eventId} not found`);
  }
  // Timezone shouldn't affect labels
  const event = new Event(dbEvent, "America/New_York");
  const eventLabels = event.guessLabels();
  const labelErrors: number[] = [];
  const labelsToAdd = [];
  for (const label_id of eventLabels) {
    labelsToAdd.push({
      event_id: eventId,
      series: null,
      label_id,
      priority: 10,
    });
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
  async queue(batch: MessageBatch<EventLabelRequest>, env: Env): Promise<void> {
    const Sentry = new Toucan({
      dsn: env.SENTRY_DSN,
      environment: env.ENV,
      release: env.RELEASE,
      dist: env.PACKAGE,
    });

    try {
      const supabase = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_KEY);

      let messageNum = 1;
      for (let message of batch.messages) {
        try {
          console.log(
            `Processing ${messageNum} of ${batch.messages.length} (${message.body.eventId})`
          );
          await labelEvent(supabase, message.body.eventId);
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
