import { Hono } from "hono";

import { Network } from "./agent/tools/network";
import type { Bindings } from "./env";

const webhook = new Hono<{ Bindings: Bindings }>();

// Webhook endpoint - handles all HTTP methods for webhook URLs
webhook.all(Network.PATH, async (c) => {
  try {
    const token = c.req.param("token");
    if (!token) {
      return new Response("Bad request (missing token)", { status: 400 });
    }

    // Extract request data
    const method = c.req.method;
    const headers: Record<string, string> = {};
    for (const [key, value] of Object.entries(c.req.header())) {
      headers[key] = value;
    }

    // Get URL parameters
    const url = new URL(c.req.url);
    const params: Record<string, string> = {};
    url.searchParams.forEach((value, key) => {
      params[key] = value;
    });

    // Parse body based on content type
    let body: any = null;
    const contentType = c.req.header("content-type");

    if (method !== "GET" && method !== "HEAD") {
      try {
        if (contentType?.includes("application/json")) {
          body = await c.req.json();
        } else if (contentType?.includes("application/x-www-form-urlencoded")) {
          body = await c.req.parseBody();
        } else {
          body = await c.req.text();
        }
      } catch (error) {
        console.warn("Failed to parse callback request body:", error);
        body = await c.req.text();
      }
    }

    const result = await Network.HandleWebhook(c.env.CALLBACKS, token, {
      method,
      headers,
      params,
      body,
    });

    // Return the result from the callback function
    if (result) {
      // @ts-ignore
      return c.json(result);
    } else {
      return new Response("OK", { status: 200 });
    }
  } catch (error) {
    console.error("Error processing callback:", error);
    return new Response("Internal server error", { status: 500 });
  }
});

export default webhook;
