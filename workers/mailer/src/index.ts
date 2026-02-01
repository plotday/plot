import { PostHog } from "posthog-node";

import { type EmailType, render } from "@plotday/email";
import { createLogger } from "@plotday/worker-util";

// ENV is defined as a global string literal in wrangler.jsonc
declare const ENV: string;

const MAX_ATTEMPTS = 10;

/**
 * Calculate exponential backoff delay for email retries.
 * Formula: min(2^attempts * 60, 3600) seconds
 * Results in: 1min, 2min, 4min, 8min, 16min, 32min, 60min (capped)
 */
function calculateBackoffDelay(attempts: number): number {
  return Math.min(Math.pow(2, attempts) * 60, 3600);
}

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

async function sendMail(apiKey: string, request: MailRequest): Promise<{ id: string }> {
  const { html, text } = await render(request.email, request.props as any);

  const isDevelopment = typeof ENV !== "undefined" && ENV === "development";

  if (isDevelopment) {
    // Development: Use Mailpit HTTP API
    const response = await fetch("http://127.0.0.1:54324/api/v1/send", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        From: { Name: "Plot", Email: "info@updates.plot.day" },
        To: request.to.map((email) => ({ Email: email })),
        Subject: request.subject,
        HTML: html,
        Text: text,
        ReplyTo: [{ Name: "Plot", Email: "team@plot.day" }],
      }),
    });

    if (!response.ok) {
      const errorText = await response.text();
      const logger = createLogger({ component: "mailer", environment: "development" });
      logger.error("Failed to send email via Mailpit", new Error(errorText));
      throw new Error(`Mailpit send failed: ${errorText}`);
    }

    const result = await response.json() as { ID: string };
    const logger = createLogger({ component: "mailer", environment: "development" });
    logger.info("Email sent to Mailpit", {
      subject: request.subject,
      recipients: request.to.join(", "),
    });

    return { id: result.ID || `dev-${Date.now()}` };
  } else {
    // Production: Use Resend HTTP API
    const response = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        from: "Plot <info@updates.plot.day>",
        reply_to: "Plot <team@plot.day>",
        to: request.to,
        subject: request.subject,
        html,
        text,
      }),
    });

    if (response.status >= 400) {
      const errorData = await response.json();
      const logger = createLogger({ component: "mailer" });
      logger.error("Email send failed", new Error(JSON.stringify(errorData)), {
        status: response.status,
        error_data: errorData
      });
      throw new Error(JSON.stringify(errorData));
    }

    const result = await response.json();
    return result as { id: string };
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
      // Cloudflare Queues has a limit of 100 messages per batch
      const BATCH_SIZE = 100;
      const batches: MessageSendRequest<MailRequest>[][] = [];

      for (let i = 0; i < body.length; i += BATCH_SIZE) {
        batches.push(body.slice(i, i + BATCH_SIZE));
      }

      // Send all batches in parallel
      await Promise.all(
        batches.map((batch) => env.QUEUE.sendBatch(batch))
      );
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
    const logger = createLogger({ component: "mailer", queue: "mail" });

    try {
      for (const message of batch.messages) {
        const { to, email: template } = message.body;

        try {
          const result = await sendMail(env.RESEND_API_KEY, message.body);

          posthog.capture({
            distinctId: "mailer-worker",
            event: "email.sent",
            properties: {
              template,
              resend_id: result.id,
              attempt: message.attempts,
            },
          });

          message.ack();
        } catch (error) {
          const errorMessage = error instanceof Error ? error.message : String(error);

          logger.error("Email send failed", error as Error, {
            to,
            attempt: message.attempts,
          });

          if (message.attempts < MAX_ATTEMPTS) {
            const delaySeconds = calculateBackoffDelay(message.attempts);

            posthog.capture({
              distinctId: "mailer-worker",
              event: "email.retry_scheduled",
              properties: {
                template,
                attempt: message.attempts,
                delay_seconds: delaySeconds,
                error: errorMessage,
              },
            });

            message.retry({ delaySeconds });
          } else {
            posthog.capture({
              distinctId: "mailer-worker",
              event: "email.expired",
              properties: {
                template,
                attempts: message.attempts,
                error: errorMessage,
              },
            });
            posthog.captureException(error as Error);

            message.ack(); // give up
          }
        }
      }
    } catch (e) {
      logger.error("Error processing email batch", e as Error);
      posthog.captureException(e as Error);
    } finally {
      ctx.waitUntil(posthog.shutdown());
    }
  },
} satisfies ExportedHandler<Env>;
