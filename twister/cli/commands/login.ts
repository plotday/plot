import { exec } from "child_process";
import * as crypto from "crypto";
import * as fs from "fs";
import * as path from "path";

import { handleNetworkError } from "../utils/network-error";
import * as out from "../utils/output";
import { getNamespacedTokenPath } from "../utils/token.js";

interface LoginOptions {
  siteUrl: string;
  apiUrl: string;
}

interface SessionResponse {
  token?: string;
  user?: {
    id: string;
    email: string;
  };
  error?: string;
}

function getTokenPath(apiUrl: string): string {
  return getNamespacedTokenPath(apiUrl);
}

function openBrowser(url: string): void {
  const command =
    process.platform === "win32"
      ? `start ${url}`
      : process.platform === "darwin"
      ? `open ${url}`
      : `xdg-open ${url}`;

  exec(command, (error) => {
    if (error) {
      out.warning("Couldn't open browser automatically", [
        `Please open: ${url}`,
      ]);
    }
  });
}

async function pollForToken(
  apiUrl: string,
  sessionId: string,
  maxAttempts = 60
): Promise<SessionResponse> {
  let consecutiveErrors = 0;
  const maxConsecutiveErrors = 3;

  for (let i = 0; i < maxAttempts; i++) {
    try {
      const response = await fetch(`${apiUrl}/v1/session/${sessionId}`);

      if (response.ok) {
        const data = (await response.json()) as SessionResponse;
        if (data.token) {
          return data;
        }
        // Reset error counter on successful request
        consecutiveErrors = 0;
      } else if (response.status === 404) {
        // Session not found yet, continue polling
        consecutiveErrors = 0;
      } else {
        const errorInfo = handleNetworkError(response);
        return { error: errorInfo.message };
      }
    } catch (error) {
      consecutiveErrors++;

      // If we've had too many consecutive errors, fail fast
      if (consecutiveErrors >= maxConsecutiveErrors) {
        const errorInfo = handleNetworkError(error);
        return { error: errorInfo.message };
      }

      // Otherwise just log and continue
      if (i === 0) {
        // Only show error on first attempt to avoid spam
        out.warning("Connection issue, retrying...");
      }
    }

    // Wait 2 seconds before next poll
    await new Promise((resolve) => setTimeout(resolve, 2000));
  }

  return { error: "Login timeout. Please try again." };
}

export async function loginCommand(options: LoginOptions) {
  out.progress("Opening browser for authorization...");

  // Generate session ID
  const sessionId = crypto.randomUUID();

  // Construct login URL
  const loginUrl = `${options.siteUrl}/twister/login?session=${sessionId}`;

  // Open browser
  openBrowser(loginUrl);

  out.plain(out.colors.dim(`If browser doesn't open: ${loginUrl}`));
  out.blank();
  out.plain("Waiting for authorization...");

  // Poll for token
  const result = await pollForToken(options.apiUrl, sessionId);

  if (result.error) {
    out.error("Login failed", result.error);
    process.exit(1);
  }

  if (!result.token) {
    out.error("Login failed", "No token received");
    process.exit(1);
  }

  // Save token to file
  const tokenPath = getTokenPath(options.apiUrl);
  const tokenDir = path.dirname(tokenPath);

  // Create directory if it doesn't exist with secure permissions
  if (!fs.existsSync(tokenDir)) {
    if (process.platform === "win32") {
      fs.mkdirSync(tokenDir, { recursive: true });
    } else {
      fs.mkdirSync(tokenDir, { recursive: true, mode: 0o700 });
    }
  }

  // Use atomic write to prevent corruption
  const tempPath = `${tokenPath}.tmp`;
  if (process.platform === "win32") {
    fs.writeFileSync(tempPath, result.token);
  } else {
    fs.writeFileSync(tempPath, result.token, { mode: 0o600 });
  }
  fs.renameSync(tempPath, tokenPath); // Atomic on most filesystems

  const details = [];
  if (result.user?.email) {
    details.push(`Logged in as ${result.user.email}`);
  }
  details.push(out.colors.dim(`Token saved to ${tokenPath}`));

  out.success("Authentication complete", details);
  out.blank();
}
