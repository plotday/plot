CREATE TABLE "public"."activity" (
    "id" uuid PRIMARY KEY DEFAULT gen_random_uuid_v7 () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "deleted_at" timestamp with time zone,
    "draft" boolean NOT NULL DEFAULT FALSE,
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "priority_id" uuid NOT NULL REFERENCES priority ON DELETE CASCADE,
    "body" text NOT NULL,
    "pinned" boolean NOT NULL DEFAULT FALSE,
    "order" double precision NOT NULL,
    "ordered_at" timestamp with time zone NOT NULL DEFAULT now(),
    "private" boolean NOT NULL DEFAULT FALSE,
    "do_at" timestamp with time zone,
    "done_at" timestamp with time zone
);

ALTER TABLE "public"."activity" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_activity_updated_at
    BEFORE UPDATE ON "public"."activity"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE UNIQUE INDEX activity_order_root ON "public"."activity" (priority_id, "order");

