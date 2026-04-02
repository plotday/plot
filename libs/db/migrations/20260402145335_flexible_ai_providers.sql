-- Drop index "idx_ai_key_org_provider" from table: "ai_key"
DROP INDEX "public"."idx_ai_key_org_provider";
-- Drop index "idx_ai_key_user_provider" from table: "ai_key"
DROP INDEX "public"."idx_ai_key_user_provider";
-- Modify "ai_key" table
ALTER TABLE "public"."ai_key" ADD COLUMN "name" text NULL, ADD COLUMN "custom_base_url" text NULL, ADD COLUMN "fast_model" text NULL, ADD COLUMN "thinking_model" text NULL;
-- Data migration: deduplicate ai_key rows (keep most recently updated per user/org + provider)
DELETE FROM "public"."ai_key" a
USING (
  SELECT user_id, organization_id, provider, MAX(updated_at) as max_updated
  FROM "public"."ai_key"
  GROUP BY user_id, organization_id, provider
  HAVING COUNT(*) > 1
) dups
WHERE a.user_id IS NOT DISTINCT FROM dups.user_id
  AND a.organization_id IS NOT DISTINCT FROM dups.organization_id
  AND a.provider = dups.provider
  AND a.updated_at < dups.max_updated;
-- Create index "idx_ai_key_org_custom" to table: "ai_key"
CREATE UNIQUE INDEX "idx_ai_key_org_custom" ON "public"."ai_key" ("organization_id", "name") WHERE ((organization_id IS NOT NULL) AND (provider = 'custom'::public.ai_provider));
-- Create index "idx_ai_key_org_standard" to table: "ai_key"
CREATE UNIQUE INDEX "idx_ai_key_org_standard" ON "public"."ai_key" ("organization_id", "provider") WHERE ((organization_id IS NOT NULL) AND (provider <> 'custom'::public.ai_provider));
-- Create index "idx_ai_key_user_custom" to table: "ai_key"
CREATE UNIQUE INDEX "idx_ai_key_user_custom" ON "public"."ai_key" ("user_id", "name") WHERE ((user_id IS NOT NULL) AND (provider = 'custom'::public.ai_provider));
-- Create index "idx_ai_key_user_standard" to table: "ai_key"
CREATE UNIQUE INDEX "idx_ai_key_user_standard" ON "public"."ai_key" ("user_id", "provider") WHERE ((user_id IS NOT NULL) AND (provider <> 'custom'::public.ai_provider));
-- Create "ai_preference" table
CREATE TABLE "public"."ai_preference" (
  "id" bigint NOT NULL GENERATED ALWAYS AS IDENTITY,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  "user_id" uuid NULL,
  "organization_id" bigint NULL,
  "builtin_ai_key_id" bigint NULL,
  "twist_ai_key_id" bigint NULL,
  "twist_ai_disabled" boolean NOT NULL DEFAULT false,
  PRIMARY KEY ("id"),
  CONSTRAINT "ai_preference_builtin_ai_key_id_fkey" FOREIGN KEY ("builtin_ai_key_id") REFERENCES "public"."ai_key" ("id") ON UPDATE NO ACTION ON DELETE SET NULL,
  CONSTRAINT "ai_preference_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organization" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "ai_preference_twist_ai_key_id_fkey" FOREIGN KEY ("twist_ai_key_id") REFERENCES "public"."ai_key" ("id") ON UPDATE NO ACTION ON DELETE SET NULL,
  CONSTRAINT "ai_preference_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."user" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "ai_preference_scope_check" CHECK (((user_id IS NOT NULL) AND (organization_id IS NULL)) OR ((user_id IS NULL) AND (organization_id IS NOT NULL)))
);
-- Create index "idx_ai_preference_org" to table: "ai_preference"
CREATE UNIQUE INDEX "idx_ai_preference_org" ON "public"."ai_preference" ("organization_id") WHERE (organization_id IS NOT NULL);
-- Create index "idx_ai_preference_user" to table: "ai_preference"
CREATE UNIQUE INDEX "idx_ai_preference_user" ON "public"."ai_preference" ("user_id") WHERE (user_id IS NOT NULL);
-- Create trigger "set_ai_preference_updated_at"
CREATE TRIGGER "set_ai_preference_updated_at" BEFORE INSERT OR UPDATE ON "public"."ai_preference" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
