import { PostHog } from "posthog-node";

import { type EmailType, render } from "@plotday/email";

// ENV is defined as a global string literal in wrangler.jsonc
declare const ENV: string;

/**
 * Parse email address in format "Name <email@example.com>" or "email@example.com"
 * into { name?: string, email: string } format for worker-mailer
 */
function parseEmailAddress(address: string): { name?: string; email: string } {
  const match = address.match(/^(.+?)\s*<(.+?)>$/);
  if (match) {
    return {
      name: match[1].trim(),
      email: match[2].trim(),
    };
  }
  return { email: address.trim() };
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

async function sendMail(apiKey: string, request: MailRequest) {
  // Fix: Use request.email and request.props instead of hardcoded values
  const { html, text } = await render(request.email, request.props as any);

  const isDevelopment = typeof ENV !== "undefined" && ENV === "development";

  if (isDevelopment) {
    // Development: Use SMTP via Inbucket
    try {
      const { WorkerMailer } = await import("worker-mailer");

      // Parse email addresses for worker-mailer format
      const parsedFrom = parseEmailAddress("Plot <info@updates.plot.day>");
      const parsedReply = parseEmailAddress("Plot <team@plot.day>");

      await WorkerMailer.send(
        {
          host: "localhost",
          port: 54325,
          secure: false,
        },
        {
          from: parsedFrom,
          to: request.to,
          subject: request.subject,
          text,
          html,
          reply: parsedReply,
        }
      );

      console.log(
        `[DEV] Email sent to Inbucket: ${request.subject} -> ${request.to.join(", ")}`
      );
    } catch (error) {
      console.error("[DEV] Failed to send email via Inbucket:", error);
      throw error;
    }
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
      const error = JSON.stringify(await response.json());
      console.error(error);
      throw new Error(error);
    }
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
    try {
      let messageNum = 1;
      for (let message of batch.messages) {
        try {
          console.log(`Processing ${messageNum} of ${batch.messages.length}`);
          await sendMail(env.RESEND_API_KEY, message.body);
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
