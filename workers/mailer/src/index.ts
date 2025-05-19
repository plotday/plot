import * as Sentry from "@sentry/cloudflare";

import { type EmailType, render } from "@plotday/email";

export { type EmailType } from "@plotday/email";

export type MailRequest = {
  to: string[];
  subject: string;
  email: EmailType;
  props?: Record<string, unknown>;
};

export interface Env {
  readonly SENTRY_DSN: string;
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

export default Sentry.withSentry(
  (env) => ({
    dsn: env.SENTRY_DSN,
    environment: ENV,
    release: RELEASE,
    dist: PACKAGE,
  }),

  {
    async fetch(req, env) {
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

    async queue(unknownBatch, env) {
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
            Sentry.withScope((scope) => {
              scope.setExtra("email", message.body.to);
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
  } satisfies ExportedHandler<Env>
);
