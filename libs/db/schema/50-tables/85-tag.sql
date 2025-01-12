CREATE TYPE item_type AS ENUM (
    'note',
    'activity'
);

CREATE TABLE "public"."tag" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "item_id" uuid NOT NULL,
    "item_type" item_type NOT NULL,
    "emoji" text NOT NULL,
    UNIQUE ("user_id", "item_type", "item_id", "emoji")
);

ALTER TABLE "public"."tag" ENABLE ROW LEVEL SECURITY;

