import * as fs from "fs";

import * as out from "../utils/output";
import { getGlobalTokenPath } from "../utils/token";
import { handleSSEStream } from "../utils/sse";

interface AgentLogsOptions {
  agentId: string;
  environment?: string;
  deployToken?: string;
  apiUrl: string;
}

/**
 * Stream agent logs in real-time
 */
export async function agentLogsCommand(options: AgentLogsOptions) {
  const { agentId, environment = "personal", apiUrl } = options;

  // Load deploy token
  let deployToken = options.deployToken;

  if (!deployToken) {
    // Try to load from PLOT_DEPLOY_TOKEN environment variable
    deployToken = process.env.PLOT_DEPLOY_TOKEN;
  }

  if (!deployToken) {
    // Try to load from global token file
    const globalTokenPath = getGlobalTokenPath();
    if (fs.existsSync(globalTokenPath)) {
      try {
        deployToken = fs.readFileSync(globalTokenPath, "utf-8").trim();
      } catch (error) {
        console.warn(
          `Warning: Failed to read global token file: ${globalTokenPath}`
        );
      }
    }
  }

  if (!deployToken) {
    out.error(
      "Authentication required",
      "Run 'plot login' or provide token via --deploy-token or PLOT_DEPLOY_TOKEN env var"
    );
    process.exit(1);
  }

  // Construct API URL
  const url = new URL(`/v1/agent/${agentId}/logs`, apiUrl);
  if (environment !== "personal") {
    url.searchParams.set("environment", environment);
  }

  out.info(`Streaming logs for agent ${agentId}`, [
    `Environment: ${environment}`,
    "Press Ctrl+C to stop",
  ]);
  out.blank();

  try {
    const response = await fetch(url.toString(), {
      method: "GET",
      headers: {
        Accept: "text/event-stream",
        Authorization: `Bearer ${deployToken}`,
      },
    });

    if (!response.ok) {
      const errorText = await response.text();
      out.error(
        `Failed to connect: ${response.status} ${response.statusText}`,
        errorText
      );
      process.exit(1);
    }

    // Handle SSE stream with custom log formatting
    await handleSSEStream(response, {
      onProgress: (message) => {
        // Initial connection message
        out.plain(message);
      },
      onEvent: (event, data) => {
        if (event === "log") {
          // Format log entry
          const { timestamp, severity, message } = data;
          const time = new Date(timestamp).toLocaleTimeString();

          // Color-code by severity
          let severityColor = "";
          let severityLabel = severity.toUpperCase().padEnd(5);

          switch (severity) {
            case "error":
              severityColor = "\x1b[31m"; // Red
              break;
            case "warn":
              severityColor = "\x1b[33m"; // Yellow
              break;
            case "info":
              severityColor = "\x1b[36m"; // Cyan
              break;
            default:
              severityColor = "\x1b[37m"; // White
          }

          const reset = "\x1b[0m";
          const gray = "\x1b[90m";

          console.log(
            `${gray}[${time}]${reset} ${severityColor}${severityLabel}${reset} ${message}`
          );
        }
      },
      onError: (error) => {
        out.error("Stream error", error);
      },
    });
  } catch (error) {
    out.error("Connection failed", String(error));
    process.exit(1);
  }
}
