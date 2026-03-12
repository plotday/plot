CREATE TABLE "public"."priority_twist_connection" (
    "priority_twist_id" uuid NOT NULL REFERENCES public.priority_twist ON DELETE CASCADE,
    "user_id" uuid NOT NULL REFERENCES public."user" ON DELETE CASCADE,
    "provider" text NOT NULL,
    "actor_id" uuid NOT NULL,
    "connected_at" timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY ("priority_twist_id", "user_id", "provider")
);

CREATE INDEX idx_ptc_user ON priority_twist_connection (user_id);
CREATE INDEX idx_ptc_priority_twist ON priority_twist_connection (priority_twist_id);
