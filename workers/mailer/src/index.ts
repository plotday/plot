import { PostHog } from "posthog-node";
import { createClient } from "@plotday/db";

import { type EmailType, render } from "@plotday/email";
import { createLogger } from "@plotday/worker-util";

// ENV is defined as a global string literal in wrangler.jsonc
declare const ENV: string;

/**
 * Calculate exponential backoff delay for email retries.
 * Formula: min(2^retryCount * 60, 3600) seconds
 * Results in: 1min, 2min, 4min, 8min, 16min, 32min, 60min (capped)
 */
function calculateBackoffDelay(retryCount: number): number {
  return Math.min(Math.pow(2, retryCount) * 60, 3600);
}

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
  idempotencyKey: string;
  to: string[];
  subject: string;
  email: EmailType;
  props?: Record<string, unknown>;
};

export interface Env {
  readonly POSTHOG_API_KEY: string;
  readonly POSTHOG_HOST: string;
  readonly RESEND_API_KEY: string;

  // Supabase bindings for email delivery tracking
  readonly SUPABASE_URL: string;
  readonly SUPABASE_SERVICE_KEY: string;

  readonly QUEUE: Queue<MailRequest>;
}

async function sendMail(apiKey: string, request: MailRequest): Promise<{ id: string }> {
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

      const logger = createLogger({ component: "mailer", environment: "development" });
      logger.info("Email sent to Inbucket", {
        subject: request.subject,
        recipients: request.to.join(", ")
      });

      // Return a mock ID for development
      return { id: `dev-${Date.now()}` };
    } catch (error) {
      const logger = createLogger({ component: "mailer", environment: "development" });
      logger.error("Failed to send email via Inbucket", error as Error);
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
    const supabase = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_KEY);
    const logger = createLogger({ component: "mailer", queue: "mail" });

    try {
      let messageNum = 1;
      for (const message of batch.messages) {
        const { idempotencyKey, to, subject, email: template, props } = message.body;

        try {
          logger.info("Processing email", {
            message_num: messageNum,
            total_messages: batch.messages.length,
            idempotency_key: idempotencyKey,
            attempt: message.attempts
          });

          // Check idempotency - skip if already sent
          const { data: emailStatus, error: statusError } = await supabase
            .from("email_delivery")
            .select("status, retry_count, max_retries")
            .eq("idempotency_key", idempotencyKey)
            .single();

          if (statusError) {
            logger.error("Failed to check email status", statusError, {
              idempotency_key: idempotencyKey
            });
            // Continue anyway - better to try sending than to fail silently
          }

          if (emailStatus?.status === "sent") {
            logger.info("Email already sent, skipping", { idempotency_key: idempotencyKey });
            message.ack();
            messageNum += 1;
            continue;
          }

          // Check if we've exceeded max retries
          if (emailStatus && emailStatus.retry_count >= emailStatus.max_retries) {
            logger.warn("Email exceeded max retries, marking as expired", {
              idempotency_key: idempotencyKey,
              retry_count: emailStatus.retry_count,
              max_retries: emailStatus.max_retries
            });

            await supabase.rpc("mark_email_expired", {
              p_idempotency_key: idempotencyKey
            });

            posthog.capture({
              distinctId: "mailer-worker",
              event: "email.expired",
              properties: {
                template,
                retry_count: emailStatus.retry_count,
                last_error: emailStatus.retry_count,
                idempotency_key: idempotencyKey
              }
            });

            message.ack(); // Remove from queue
            messageNum += 1;
            continue;
          }

          // Send email via Resend
          const result = await sendMail(env.RESEND_API_KEY, message.body);

          // Mark as sent in database
          await supabase.rpc("mark_email_sent", {
            p_idempotency_key: idempotencyKey,
            p_resend_id: result.id,
          });

          // Update contact_invitation.sent_at if applicable
          if (template === "priority-invitation") {
            const contactId = props?.contactId;
            if (contactId) {
              await supabase.rpc("update_invitation_sent_at", {
                p_contact_id: contactId,
              });
            }
          }

          logger.info("Email sent successfully", {
            idempotency_key: idempotencyKey,
            resend_id: result.id,
            attempt: message.attempts
          });

          posthog.capture({
            distinctId: "mailer-worker",
            event: "email.sent",
            properties: {
              template,
              resend_id: result.id,
              retry_count: emailStatus?.retry_count || 0,
              attempt_number: message.attempts,
              idempotency_key: idempotencyKey
            }
          });

          message.ack(); // Remove from queue

        } catch (error) {
          const errorMessage = error instanceof Error ? error.message : String(error);

          logger.error("Email send failed", error as Error, {
            idempotency_key: idempotencyKey,
            to: to,
            attempt: message.attempts
          });

          // Increment retry count and get current state
          const { data: retryState, error: retryError } = await supabase.rpc(
            "increment_email_retry",
            {
              p_idempotency_key: idempotencyKey,
              p_error: errorMessage,
            }
          );

          if (retryError) {
            logger.error("Failed to increment retry count", retryError, {
              idempotency_key: idempotencyKey
            });
            // Retry with default delay anyway
            message.retry({ delaySeconds: 60 });
            messageNum += 1;
            continue;
          }

          const { retry_count, max_retries, should_expire } = retryState[0];

          if (should_expire) {
            // Mark as expired and remove from queue
            await supabase.rpc("mark_email_expired", {
              p_idempotency_key: idempotencyKey
            });

            logger.warn("Email expired after max retries", {
              idempotency_key: idempotencyKey,
              retry_count: retry_count,
              max_retries: max_retries
            });

            posthog.capture({
              distinctId: "mailer-worker",
              event: "email.expired",
              properties: {
                template,
                retry_count: retry_count,
                last_error: errorMessage,
                idempotency_key: idempotencyKey
              }
            });
            posthog.captureException(error as Error, undefined, {
              idempotency_key: idempotencyKey,
              retry_count: retry_count,
              to: to
            });

            message.ack(); // Remove from queue
          } else {
            // Calculate exponential backoff delay
            const delaySeconds = calculateBackoffDelay(retry_count);
            const nextAttemptAt = new Date(Date.now() + delaySeconds * 1000);

            logger.info("Scheduling email retry", {
              idempotency_key: idempotencyKey,
              retry_count: retry_count,
              delay_seconds: delaySeconds,
              next_attempt_at: nextAttemptAt.toISOString()
            });

            posthog.capture({
              distinctId: "mailer-worker",
              event: "email.retry_scheduled",
              properties: {
                template,
                retry_count: retry_count,
                delay_seconds: delaySeconds,
                next_attempt_at: nextAttemptAt.toISOString(),
                error: errorMessage,
                idempotency_key: idempotencyKey
              }
            });
            posthog.captureException(error as Error, undefined, {
              idempotency_key: idempotencyKey,
              retry_count: retry_count,
              to: to
            });

            // Retry with exponential backoff
            message.retry({ delaySeconds });
          }
        }

        messageNum += 1;
      }
    } catch (e) {
      logger.error("Error processing email batch", e as Error);
      posthog.captureException(e as Error);
    } finally {
      ctx.waitUntil(posthog.shutdown());
    }
  },
} satisfies ExportedHandler<Env>;
