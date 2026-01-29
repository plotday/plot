CREATE TABLE "public"."priority_contact" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "invited_at" timestamp with time zone,
    "priority_id" uuid NOT NULL REFERENCES public.priority ON DELETE CASCADE,
    "contact_id" uuid NOT NULL REFERENCES public.contact ON DELETE CASCADE,
    "invited_by" uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    CONSTRAINT priority_contact_unique UNIQUE (priority_id, contact_id)
);

ALTER TABLE "public"."priority_contact" ENABLE ROW LEVEL SECURITY;
