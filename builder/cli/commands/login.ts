import { exec } from "child_process";
import * as crypto from "crypto";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";

import * as out from "../utils/output";

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

function getTokenPath(): string {
  const homeDir = os.homedir();
  if (process.platform === "win32") {
    // Windows: Use APPDATA
    const appData =
      process.env.APPDATA || path.join(homeDir, "AppData", "Roaming");
    return path.join(appData, "plot", "token");
  } else {
    // Unix-like: Use ~/.config/plot/token
    return path.join(homeDir, ".config", "plot", "token");
  }
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
  for (let i = 0; i < maxAttempts; i++) {
    try {
      const response = await fetch(`${apiUrl}/v1/session/${sessionId}`);

      if (response.ok) {
        const data = (await response.json()) as SessionResponse;
        if (data.token) {
          return data;
        }
      } else if (response.status === 404) {
        // Session not found yet, continue polling
      } else {
        const errorText = await response.text();
        return { error: `Server error: ${response.status} ${errorText}` };
      }
    } catch (error) {
      console.error("Polling error:", error);
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
  const loginUrl = `${options.siteUrl}/builder/login?session=${sessionId}`;

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
  const tokenPath = getTokenPath();
  const tokenDir = path.dirname(tokenPath);

  // Create directory if it doesn't exist
  if (!fs.existsSync(tokenDir)) {
    fs.mkdirSync(tokenDir, { recursive: true });
  }

  // Write token with secure permissions
  // Note: mode option is only supported on Unix-like systems
  // On Windows, file permissions are handled differently
  if (process.platform === "win32") {
    fs.writeFileSync(tokenPath, result.token);
  } else {
    fs.writeFileSync(tokenPath, result.token, { mode: 0o600 });
  }

  const details = [];
  if (result.user?.email) {
    details.push(`Logged in as ${result.user.email}`);
  }
  details.push(out.colors.dim(`Token saved to ${tokenPath}`));

  out.success("Authentication complete", details);
  out.blank();
}
