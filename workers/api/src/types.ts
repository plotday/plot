import { z } from "zod";

// Zod schemas for validated sync notification payloads.
// These mirror the columns exposed by the corresponding user.* views.
// Field type rules:
//   - Nullable DB columns → .nullable()
//   - Non-null DB columns → no .nullable() / .optional()
//   - xid8 columns serialize as string

export const TeamUserItemSchema = z.object({
  id: z.number(),
  user_id: z.string(),
  team_id: z.number(),
  role: z.enum(["admin", "member"]),
  archived_at: z.string().nullable(),
  seq: z.string(), // xid8 serializes as string
  team_name: z.string(),
});

export type TeamUserItem = z.infer<typeof TeamUserItemSchema>;
