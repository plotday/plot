ALTER TABLE "public"."calendar"
    ADD COLUMN "category" text;

ALTER TABLE "public"."user"
    ADD COLUMN "default_category" text;

CREATE UNIQUE INDEX category_user_path ON public.category USING btree (user_id, path);

ALTER TABLE "public"."category"
    ADD CONSTRAINT "category_user_path" UNIQUE USING INDEX "category_user_path";

