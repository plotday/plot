import { type z } from "zod";
import {
  ActivityItemSchema,
  NoteItemSchema,
  PriorityItemSchema,
  SessionItemSchema,
  PriorityTwistItemSchema,
  ActivityReadItemSchema,
} from "../types";

/**
 * Helper function for handling validation errors
 */
export function handleValidationError(error: z.ZodError, rawData?: any): Response {
  const messages = error.issues.map((e) => {
    const path = e.path.join(".");
    let suggestion = "";

    // Provide helpful suggestions for common validation errors
    if (path.includes("created_by")) {
      suggestion = " (Expected: uuid string. Check that 'created_by' field matches database schema in workers/api/src/types.ts:ActivityItemSchema)";
    } else if (path.includes("meta")) {
      suggestion = " (Expected: nullable object. Check that 'meta' field matches database schema in workers/api/src/types.ts:ActivityItemSchema)";
    } else if (path.includes("mentions")) {
      suggestion = " (Expected: nullable array of uuid strings. Check that 'mentions' field matches database schema in workers/api/src/types.ts:ActivityItemSchema)";
    } else if (path.includes("tags")) {
      suggestion = " (Expected: nullable object. This is an enriched field from database JOINs)";
    } else if (path.includes("item") && e.code === "invalid_union") {
      // For union validation failures, try to determine which schema was closest
      const itemData = rawData?.item;
      if (itemData) {
        const detailedErrors = getDetailedUnionErrors(itemData);
        suggestion = `\n\nDetailed validation errors for each item type:\n${detailedErrors}`;
      } else {
        suggestion = " (Item validation failed. Check that all required fields (id, created_by, author_id, etc.) are present and match the database schema in workers/api/src/types.ts)";
      }
    }

    return `${path}: ${e.message}${suggestion}`;
  });

  console.warn("Validation error:", messages);

  // Include a sample of the raw data if available (first 500 chars)
  let dataSample = "";
  if (rawData) {
    try {
      const dataStr = JSON.stringify(rawData, null, 2);
      dataSample = `\n\nData sample (first 500 chars):\n${dataStr.slice(0, 500)}${dataStr.length > 500 ? "..." : ""}`;
    } catch (e) {
      dataSample = "\n\n(Could not stringify data sample)";
    }
  }

  return new Response(
    `Validation error: ${messages.join("\n")}${dataSample}\n\nTo fix: Update the database trigger or validation schema in workers/api/src/types.ts to match the database schema in libs/db/schema/50-tables/*.sql`,
    {
      status: 400,
    }
  );
}

/**
 * Try to validate against each union member and return detailed errors
 */
function getDetailedUnionErrors(itemData: any): string {
  const schemas = [
    { name: "ActivityItemSchema", schema: ActivityItemSchema },
    { name: "NoteItemSchema", schema: NoteItemSchema },
    { name: "PriorityItemSchema", schema: PriorityItemSchema },
    { name: "SessionItemSchema", schema: SessionItemSchema },
    { name: "PriorityTwistItemSchema", schema: PriorityTwistItemSchema },
    { name: "ActivityReadItemSchema", schema: ActivityReadItemSchema },
  ];

  const results = schemas.map(({ name, schema }) => {
    const result = schema.safeParse(itemData);
    if (result.success) {
      return `  ✓ ${name}: PASSED`;
    } else {
      const firstFewErrors = result.error.issues.slice(0, 5).map((issue) => {
        const path = issue.path.join(".");
        return `      - ${path || "root"}: ${issue.message}`;
      });
      const remaining = result.error.issues.length - 5;
      const remainingMsg = remaining > 0 ? `\n      ... and ${remaining} more errors` : "";
      return `  ✗ ${name}: FAILED\n${firstFewErrors.join("\n")}${remainingMsg}`;
    }
  });

  return results.join("\n");
}
