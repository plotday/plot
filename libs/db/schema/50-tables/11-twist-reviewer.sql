-- Users who can see all twists in the 'review' environment.
CREATE TABLE "public"."twist_reviewer" (
    "user_id" uuid PRIMARY KEY REFERENCES public."user" ON DELETE CASCADE,
    "created_at" timestamp with time zone NOT NULL DEFAULT now()
);
