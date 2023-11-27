import { z } from "zod";

import { safeQuery } from "@plotday/db";

import { privateAction } from "app/util";

export const action = privateAction(async ({ request, user, supabase }) => {
  switch (request.method) {
    case "POST": {
      const schema = z.object({
        categoryId: z.coerce.number(),
        body: z.string(),
      });
      const data = schema.parse(Object.fromEntries(await request.formData()));
      safeQuery(
        await supabase.from("note").insert({
          category_id: data.categoryId,
          body: data.body,
          author: user.id,
        })
      );
      return null;
    }

    default:
      return new Response("Unsupported method", { status: 405 });
  }
});
