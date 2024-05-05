CREATE TABLE "public"."note" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "context_id" bigint REFERENCES context ON DELETE CASCADE,
    "body" text NOT NULL
);

ALTER TABLE "public"."note" ENABLE ROW LEVEL SECURITY;

