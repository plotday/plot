-- Create "thread_notify_state" table
CREATE TABLE "public"."thread_notify_state" (
  "user_id" uuid NOT NULL,
  "thread_id" uuid NOT NULL,
  "notified_at" timestamptz NOT NULL,
  PRIMARY KEY ("user_id", "thread_id"),
  CONSTRAINT "thread_notify_state_thread_id_fkey" FOREIGN KEY ("thread_id") REFERENCES "public"."thread" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "thread_notify_state_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."user" ("id") ON UPDATE NO ACTION ON DELETE CASCADE
);
-- Grant data access to the api role and read access to readonly (default
-- privileges do not auto-apply under Atlas-applied migrations).
GRANT SELECT, INSERT, UPDATE, DELETE ON "public"."thread_notify_state" TO api;
GRANT SELECT ON "public"."thread_notify_state" TO readonly;
