CREATE TABLE "public"."invitation" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "code" text NOT NULL,
    "remaining" numeric NOT NULL DEFAULT '1' ::numeric
);

ALTER TABLE "public"."invitation" ENABLE ROW LEVEL SECURITY;

-- Case-insensitive unique index on code
CREATE UNIQUE INDEX invitation_code_lower_unique ON invitation (LOWER(code));

