import { render } from "@plotday/email";
import { createLogger } from "@plotday/worker-util";

import { type Bindings } from "../env";

type MailRequest = {
  to: string[];
  subject: string;
  email: string;
  props?: Record<string, unknown>;
};

const logger = createLogger({ component: "mailer", queue: "mail-development" });

/**
 * Process mail queue messages in development.
 *
 * In production, the separate mailer worker handles this queue.
 * In development, wrangler dev doesn't reliably route queues between
 * workers, so the API worker consumes mail messages directly and
 * sends them to the local Mailpit instance.
 */
export async function processMail(
  batch: MessageBatch<MailRequest>,
  _env: Bindings,
  _ctx: ExecutionContext
): Promise<void> {
  for (const message of batch.messages) {
    const { to, subject, email, props } = message.body;

    try {
      const { html, text } = await render(email as any, props as any);

      const response = await fetch("http://127.0.0.1:54324/api/v1/send", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          From: { Name: "Plot", Email: "info@updates.plot.day" },
          To: to.map((addr) => ({ Email: addr })),
          Subject: subject,
          HTML: html,
          Text: text,
          ReplyTo: [{ Name: "Plot", Email: "team@plot.day" }],
        }),
      });

      if (!response.ok) {
        const errorText = await response.text();
        throw new Error(`Mailpit send failed: ${errorText}`);
      }

      logger.info("Email sent to Mailpit", {
        subject,
        recipients: to.join(", "),
      });

      message.ack();
    } catch (error) {
      logger.error("Failed to send dev email", error as Error, {
        to,
        subject,
        attempt: message.attempts,
      });

      if (message.attempts < 3) {
        message.retry({ delaySeconds: 5 });
      } else {
        // Give up after 3 attempts in dev
        message.ack();
      }
    }
  }
}
