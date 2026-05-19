-- Modify "priority" table
ALTER TABLE "public"."priority" ADD COLUMN "team_id" bigint NULL, ADD CONSTRAINT "priority_team_id_fkey" FOREIGN KEY ("team_id") REFERENCES "public"."team" ("id") ON UPDATE NO ACTION ON DELETE RESTRICT;
-- Create index "idx_priority_team_id" to table: "priority"
CREATE INDEX "idx_priority_team_id" ON "public"."priority" ("team_id") WHERE (team_id IS NOT NULL);
