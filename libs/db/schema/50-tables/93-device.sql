CREATE TABLE "public"."device" (
    "id" uuid PRIMARY KEY DEFAULT uuidv7 () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES public."user" ON DELETE CASCADE,
    "platform" text NOT NULL CHECK (platform IN ('ios', 'android')),
    "push_token" text NOT NULL UNIQUE,
    "app_version" text
);

CREATE INDEX idx_device_user_id ON "public"."device" (user_id);

CREATE TRIGGER set_device_updated_at
    BEFORE INSERT OR UPDATE ON "public"."device"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_device_created_at
    BEFORE INSERT ON "public"."device"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();
