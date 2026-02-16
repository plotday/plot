-- WARNING! This table is currently readable by all users.
-- WARNING! Changes will be needed if adding sensitive fields.
CREATE TABLE "public"."organization" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "name" text NOT NULL
);

