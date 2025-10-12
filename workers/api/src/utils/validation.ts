import { type z } from "zod";

/**
 * Helper function for handling validation errors
 */
export function handleValidationError(error: z.ZodError): Response {
  const messages = error.issues.map((e) => `${e.path.join(".")}: ${e.message}`);
  console.warn("Validation error:", messages);
  return new Response(`Validation error: ${messages.join(", ")}`, {
    status: 400,
  });
}
