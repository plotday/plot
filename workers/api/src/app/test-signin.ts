import { Hono } from "hono";
import { z } from "zod";
import { createClerkClient } from "@clerk/backend";

import { createLogger } from "@plotday/worker-util";

import type { Bindings } from "../env";
import { corsMiddleware } from "./cors";
import { authRateLimiter } from "../middleware/rate-limit";
import { extractRequestContext } from "../utils/log-context";
import { handleValidationError } from "../utils/validation";
import { captureServerError } from "../utils/error-capture";

/**
 * Hardcoded allowlist of accounts that may use the server-issued sign-in
 * ticket path. This bypasses Clerk's first-factor flow — including any
 * `needs_second_factor` email OTP challenge — for shared test accounts that
 * external reviewers must be able to sign in to without access to the inbox.
 *
 * Changes require code review + deploy by design.
 */
const ALLOWED_EMAILS = new Set(["tester@plot.day"]);

const TestSignInSchema = z.object({
  email: z.email(),
  password: z.string().min(1),
});

const testSignIn = new Hono<{ Bindings: Bindings }>();

// CORS so the Flutter web build (and preview.plot.day) can call this from the
// browser. Mounted at the root of the worker (outside `appSection`), so we
// reuse the same allowlist explicitly rather than picking it up by mount path.
testSignIn.use("/auth/test-signin", corsMiddleware);
testSignIn.use("/auth/test-signin", authRateLimiter);

testSignIn.post("/auth/test-signin", async (c) => {
  const logger = createLogger(extractRequestContext(c));

  const parsed = TestSignInSchema.safeParse(await c.req.json().catch(() => ({})));
  if (!parsed.success) {
    return handleValidationError(parsed.error);
  }

  const { email, password } = parsed.data;
  const normalizedEmail = email.trim().toLowerCase();

  if (!ALLOWED_EMAILS.has(normalizedEmail)) {
    // Return 401 (not 403) so an attacker probing the endpoint can't
    // distinguish allowlisted-with-wrong-password from not-allowlisted.
    return c.json({ message: "Invalid credentials" }, 401);
  }

  const clerk = createClerkClient({ secretKey: c.env.CLERK_SECRET_KEY });

  try {
    const { data: users } = await clerk.users.getUserList({
      emailAddress: [normalizedEmail],
      limit: 1,
    });
    const user = users[0];
    if (!user) {
      return c.json({ message: "Invalid credentials" }, 401);
    }

    try {
      await clerk.users.verifyPassword({ userId: user.id, password });
    } catch {
      // Clerk returns 422 for an incorrect password. Collapse every
      // verifyPassword failure to a generic 401 so the response shape
      // matches the not-allowlisted branch above.
      return c.json({ message: "Invalid credentials" }, 401);
    }

    const token = await clerk.signInTokens.createSignInToken({
      userId: user.id,
      expiresInSeconds: 60,
    });

    logger.info("Issued test sign-in ticket", {
      email: normalizedEmail,
      clerk_id: user.id,
    });

    return c.json({ ticket: token.token });
  } catch (err) {
    return captureServerError(c, err, "Failed to issue test sign-in ticket", {
      email: normalizedEmail,
    });
  }
});

export default testSignIn;
