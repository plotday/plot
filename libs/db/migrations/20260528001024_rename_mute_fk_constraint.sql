-- Modify "thread_priority" table
ALTER TABLE "public"."thread_priority" DROP CONSTRAINT "thread_priority_auto_archived_by_thread_id_fkey", ADD CONSTRAINT "thread_priority_mute_by_thread_id_fkey" FOREIGN KEY ("mute_by_thread_id") REFERENCES "public"."thread" ("id") ON UPDATE NO ACTION ON DELETE SET NULL;
