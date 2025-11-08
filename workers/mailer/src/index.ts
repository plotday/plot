import { PostHog } from "posthog-node";

import { type EmailType, render } from "@plotday/email";

export { type EmailType } from "@plotday/email";

export type MailRequest = {
  to: string[];
  subject: string;
  email: EmailType;
  props?: Record<string, unknown>;
};

export interface Env {
  readonly POSTHOG_API_KEY: string;
  readonly POSTHOG_HOST: string;
  readonly RESEND_API_KEY: string;

  readonly QUEUE: Queue<MailRequest>;
}

async function resend(apiKey: string, request: MailRequest) {
  const { html, text } = render("waitlist-welcome", {});
  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      from: "Plot <info@xn--4bi.plot.day>",
      reply_to: "Plot <info@plot.day>",
      to: request.to,
      subject: request.subject,
      html,
      text,
    }),
  });
  if (response.status >= 400) {
    const error = JSON.stringify(await response.json());
    console.error(error);
    throw new Error(error);
  }
}

export default {
  async fetch(req, env: Env) {
    if (req.method !== "POST") {
      return new Response("Method Not Allowed", { status: 405 });
    }
    if (ENV !== "development") {
      return new Response("Forbidden", { status: 403 });
    }
    const body = (await req.json()) as
      | MailRequest
      | MessageSendRequest<MailRequest>[];
    if (body instanceof Array) {
      await env.QUEUE.sendBatch(body);
    } else {
      await env.QUEUE.send(body);
    }

    return new Response("Sync queued");
  },

  async queue(unknownBatch, env, ctx) {
    const posthog = new PostHog(env.POSTHOG_API_KEY, {
      host: env.POSTHOG_HOST,
      flushAt: 5,
      flushInterval: 10,
    });
    const batch = unknownBatch as MessageBatch<MailRequest>;
    try {
      let messageNum = 1;
      for (let message of batch.messages) {
        try {
          console.log(`Processing ${messageNum} of ${batch.messages.length}`);
          await resend(env.RESEND_API_KEY, message.body);
          message.ack();
        } catch (e) {
          console.error(e);
          posthog.captureException(e as Error, undefined, {
            to: message.body.to,
          });
          message.retry();
        }
        messageNum += 1;
      }
    } catch (e) {
      console.error(e);
      posthog.captureException(e as Error);
    } finally {
      ctx.waitUntil(posthog.shutdown());
    }
  },
} satisfies ExportedHandler<Env>;
