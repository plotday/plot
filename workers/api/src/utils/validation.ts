import { type z } from "zod";

/**
 * Helper function for handling validation errors
 */
export function handleValidationError(error: z.ZodError): Response {
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
      suggestion = " (Item validation failed. Check that all required fields (id, created_by, author_id, etc.) are present and match the database schema in workers/api/src/types.ts)";
    }

    return `${path}: ${e.message}${suggestion}`;
  });

  console.warn("Validation error:", messages);

  return new Response(
    `Validation error: ${messages.join(", ")}\n\nTo fix: Update the database trigger or validation schema in workers/api/src/types.ts to match the database schema in libs/db/schema/50-tables/*.sql`,
    {
      status: 400,
    }
  );
}
