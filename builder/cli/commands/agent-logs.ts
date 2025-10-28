import * as fs from "fs";
import * as path from "path";

import * as out from "../utils/output";
import { getGlobalTokenPath } from "../utils/token";
import { handleSSEStream } from "../utils/sse";

interface PackageJson {
  plotAgentId?: string;
}

interface AgentLogsOptions {
  agentId?: string;
  id?: string;
  dir?: string;
  environment?: string;
  deployToken?: string;
  apiUrl: string;
}

/**
 * Stream agent logs in real-time
 */
export async function agentLogsCommand(options: AgentLogsOptions) {
  const { environment = "personal", apiUrl, dir = process.cwd() } = options;

  // Determine agent ID from options, positional arg, or package.json
  let agentId = options.id || options.agentId;

  if (!agentId) {
    // Try to read from package.json
    const packageJsonPath = path.join(dir, "package.json");
    if (fs.existsSync(packageJsonPath)) {
      try {
        const packageJsonContent = fs.readFileSync(packageJsonPath, "utf-8");
        const packageJson: PackageJson = JSON.parse(packageJsonContent);
        agentId = packageJson.plotAgentId;
      } catch (error) {
        out.error("Failed to parse package.json", String(error));
        process.exit(1);
      }
    }
  }

  if (!agentId) {
    out.error(
      "Agent ID required",
      "Provide agent ID as argument, via --id flag, or add 'plotAgentId' to package.json"
    );
    process.exit(1);
  }

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
          const time = new Date(timestamp).toLocaleTimeString("en-US", {
            hour12: true,
            hour: "2-digit",
            minute: "2-digit",
            second: "2-digit",
          });

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

          // Split message into lines for multi-line formatting
          const lines = message.split("\n");
          const firstLine = lines[0];
          const restLines = lines.slice(1);

          // Print first line with timestamp/severity
          console.log(
            `${gray}[${time}]${reset} ${severityColor}${severityLabel}${reset} ${firstLine}`
          );

          // Print continuation lines with box-drawing characters for stack frames
          // Indent = 13 chars "[01:38:09 PM] " + 7 chars "ERROR " = 20 spaces
          const indent = " ".repeat(20);
          for (let i = 0; i < restLines.length; i++) {
            const line = restLines[i];

            // Check if this is a stack trace line (starts with whitespace + "at")
            const isStackFrame = /^\s+at\s/.test(line);

            if (isStackFrame) {
              // Find if this is the last stack frame
              const remainingLines = restLines.slice(i + 1);
              const hasMoreStackFrames = remainingLines.some(
                (l: string) => /^\s+at\s/.test(l)
              );

              // Remove leading spaces from the line (but keep "at" and everything after)
              const trimmedLine = line.trimStart();

              // Add box-drawing character: ┊ for middle frames, └ for last frame
              const prefix = hasMoreStackFrames ? "┊" : "└";
              console.log(`${indent}${prefix} ${trimmedLine}`);
            } else {
              // Regular continuation line (like "Error: Debugging")
              console.log(`${indent}${line}`);
            }
          }
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
