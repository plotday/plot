import { type z } from "zod";
import { createLogger } from "@plotday/worker-util";

/**
 * Helper function for handling validation errors from Zod schemas.
 * Provides detailed error messages and suggestions for common validation issues.
 */
export function handleValidationError(error: z.ZodError, rawData?: any): Response {
  const logger = createLogger({
    operation: "validation",
  });

  logger.error("Validation error", error, { raw_data: rawData });

  const messages = error.issues.map((e) => {
    const path = e.path.join(".");
    return `${path}: ${e.message}`;
  });

  logger.error("Validation issues", { issues: messages });

  // Include a sample of the raw data if available (first 1000 chars for response)
  let dataSample = "";
  if (rawData) {
    try {
      const dataStr = JSON.stringify(rawData, null, 2);
      dataSample = `\n\nData sample (first 1000 chars):\n${dataStr.slice(0, 1000)}${dataStr.length > 1000 ? "..." : ""}`;
    } catch (e) {
      dataSample = "\n\n(Could not stringify data sample)";
    }
  }

  return new Response(
    `Validation error: ${messages.join("\n")}${dataSample}`,
    {
      status: 400,
    }
  );
}
