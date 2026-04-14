CREATE TABLE "public"."twist_instance_connection" (
    "twist_instance_id" uuid NOT NULL REFERENCES public.twist_instance ON DELETE CASCADE,
    "user_id" uuid NOT NULL REFERENCES public."user" ON DELETE CASCADE,
    "provider" text NOT NULL,
    "actor_id" uuid NOT NULL,
    "connected_at" timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY ("twist_instance_id", "user_id", "provider")
);

CREATE INDEX idx_twist_instance_connection_user_id ON twist_instance_connection (user_id);
CREATE INDEX idx_twist_instance_connection_instance ON twist_instance_connection (twist_instance_id);
