CREATE TABLE "public"."twist_admin" (
    "id" bigint NOT NULL GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    "twist_package_id" uuid NOT NULL DEFAULT uuidv7 (),
    "user_id" uuid REFERENCES public."user" ON DELETE CASCADE,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "publisher_id" bigint REFERENCES public.publisher ON DELETE CASCADE,
    "priority_id" uuid REFERENCES public.priority ON DELETE CASCADE,
    "auto_approve" boolean NOT NULL DEFAULT FALSE,
    CONSTRAINT "twist_admin_ownership_check" CHECK (
        (publisher_id IS NOT NULL AND user_id IS NULL)
        OR
        (publisher_id IS NULL AND user_id IS NOT NULL)
    ),
    CONSTRAINT "twist_admin_package_user_unique" UNIQUE NULLS NOT DISTINCT ("twist_package_id", "user_id")
);

CREATE TRIGGER set_twist_admin_updated_at
    BEFORE INSERT OR UPDATE ON "public"."twist_admin"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_twist_admin_created_at
    BEFORE INSERT ON "public"."twist_admin"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

-- Indexes for foreign key performance
CREATE INDEX idx_twist_admin_user_id ON "public"."twist_admin" (user_id);

CREATE INDEX idx_twist_admin_publisher_id ON "public"."twist_admin" (publisher_id);

CREATE INDEX idx_twist_admin_priority_id ON "public"."twist_admin" (priority_id);
