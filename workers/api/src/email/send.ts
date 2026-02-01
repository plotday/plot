/**
 * Email service abstraction that routes emails based on environment:
 * - Development: Mailpit HTTP API (localhost:54324)
 * - Production: Resend HTTP API
 */

// ENV is defined as a global string literal in wrangler.jsonc
declare const ENV: string;

/**
 * Parse email address in format "Name <email@example.com>" or "email@example.com"
 * into { name?: string, email: string } format
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

export interface EmailParams {
  from: string;
  to: string[];
  subject: string;
  html: string;
  text: string;
  replyTo?: string;
}

export interface EmailResult {
  success: boolean;
  error?: string;
}

/**
 * Send an email using the appropriate transport for the environment.
 *
 * In development (ENV === "development"), uses Mailpit HTTP API.
 * In production, uses Resend HTTP API.
 */
export async function sendEmail(
  params: EmailParams,
  resendApiKey?: string
): Promise<EmailResult> {
  const { from, to, subject, html, text, replyTo } = params;

  // Detect environment (ENV is a global variable defined in wrangler.jsonc)
  const isDevelopment = typeof ENV !== "undefined" && ENV === "development";

  if (isDevelopment) {
    // Development: Use Mailpit HTTP API
    try {
      const parsedFrom = parseEmailAddress(from);
      const parsedReplyTo = replyTo ? parseEmailAddress(replyTo) : undefined;

      const response = await fetch("http://127.0.0.1:54324/api/v1/send", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          From: { Name: parsedFrom.name, Email: parsedFrom.email },
          To: to.map((email) => ({ Email: email })),
          Subject: subject,
          HTML: html,
          Text: text,
          ...(parsedReplyTo
            ? { ReplyTo: [{ Name: parsedReplyTo.name, Email: parsedReplyTo.email }] }
            : {}),
        }),
      });

      if (!response.ok) {
        const errorText = await response.text();
        console.error("[DEV] Failed to send email via Mailpit:", errorText);
        return { success: false, error: `mailpit_send_failed: ${errorText}` };
      }

      console.log(`[DEV] Email sent to Mailpit: ${subject} -> ${to.join(", ")}`);
      console.log(`[DEV] View at: http://localhost:54324`);
      return { success: true };
    } catch (error) {
      console.error("[DEV] Failed to send email via Mailpit:", error);
      return {
        success: false,
        error: `mailpit_send_failed: ${error instanceof Error ? error.message : String(error)}`,
      };
    }
  } else {
    // Production: Use Resend HTTP API
    if (!resendApiKey) {
      console.error("Resend API key is required in production");
      return { success: false, error: "missing_api_key" };
    }

    try {
      const emailResponse = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${resendApiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          from,
          to,
          subject,
          html,
          text,
          ...(replyTo ? { reply_to: replyTo } : {}),
        }),
      });

      if (!emailResponse.ok) {
        const errorBody = await emailResponse.text();
        console.error("Failed to send email via Resend:", errorBody);
        return { success: false, error: "resend_api_error" };
      }

      return { success: true };
    } catch (error) {
      console.error("Failed to send email via Resend:", error);
      return {
        success: false,
        error: `resend_send_failed: ${error instanceof Error ? error.message : String(error)}`,
      };
    }
  }
}
