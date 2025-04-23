CREATE TABLE "public"."tag" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "priority_id" uuid REFERENCES priority ON DELETE SET NULL,
    "emoji" text NOT NULL,
    UNIQUE ("user_id", "priority_id", "emoji")
);

ALTER TABLE "public"."tag" ENABLE ROW LEVEL SECURITY;

