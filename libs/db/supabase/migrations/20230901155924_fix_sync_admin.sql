REVOKE DELETE ON TABLE "public"."account" FROM "internal_admin";

REVOKE INSERT ON TABLE "public"."account" FROM "internal_admin";

REVOKE REFERENCES ON TABLE "public"."account" FROM "internal_admin";

REVOKE SELECT ON TABLE "public"."account" FROM "internal_admin";

REVOKE TRIGGER ON TABLE "public"."account" FROM "internal_admin";

REVOKE TRUNCATE ON TABLE "public"."account" FROM "internal_admin";

REVOKE UPDATE ON TABLE "public"."account" FROM "internal_admin";

REVOKE DELETE ON TABLE "public"."calendar" FROM "internal_admin";

REVOKE INSERT ON TABLE "public"."calendar" FROM "internal_admin";

REVOKE REFERENCES ON TABLE "public"."calendar" FROM "internal_admin";

REVOKE SELECT ON TABLE "public"."calendar" FROM "internal_admin";

REVOKE TRIGGER ON TABLE "public"."calendar" FROM "internal_admin";

REVOKE TRUNCATE ON TABLE "public"."calendar" FROM "internal_admin";

REVOKE UPDATE ON TABLE "public"."calendar" FROM "internal_admin";

REVOKE DELETE ON TABLE "public"."contact" FROM "internal_admin";

REVOKE INSERT ON TABLE "public"."contact" FROM "internal_admin";

REVOKE REFERENCES ON TABLE "public"."contact" FROM "internal_admin";

REVOKE SELECT ON TABLE "public"."contact" FROM "internal_admin";

REVOKE TRIGGER ON TABLE "public"."contact" FROM "internal_admin";

REVOKE TRUNCATE ON TABLE "public"."contact" FROM "internal_admin";

REVOKE UPDATE ON TABLE "public"."contact" FROM "internal_admin";

REVOKE DELETE ON TABLE "public"."domain" FROM "internal_admin";

REVOKE INSERT ON TABLE "public"."domain" FROM "internal_admin";

REVOKE REFERENCES ON TABLE "public"."domain" FROM "internal_admin";

REVOKE SELECT ON TABLE "public"."domain" FROM "internal_admin";

REVOKE TRIGGER ON TABLE "public"."domain" FROM "internal_admin";

REVOKE TRUNCATE ON TABLE "public"."domain" FROM "internal_admin";

REVOKE UPDATE ON TABLE "public"."domain" FROM "internal_admin";

REVOKE DELETE ON TABLE "public"."event" FROM "internal_admin";

REVOKE INSERT ON TABLE "public"."event" FROM "internal_admin";

REVOKE REFERENCES ON TABLE "public"."event" FROM "internal_admin";

REVOKE SELECT ON TABLE "public"."event" FROM "internal_admin";

REVOKE TRIGGER ON TABLE "public"."event" FROM "internal_admin";

REVOKE TRUNCATE ON TABLE "public"."event" FROM "internal_admin";

REVOKE UPDATE ON TABLE "public"."event" FROM "internal_admin";

REVOKE DELETE ON TABLE "public"."invitation" FROM "internal_admin";

REVOKE INSERT ON TABLE "public"."invitation" FROM "internal_admin";

REVOKE REFERENCES ON TABLE "public"."invitation" FROM "internal_admin";

REVOKE SELECT ON TABLE "public"."invitation" FROM "internal_admin";

REVOKE TRIGGER ON TABLE "public"."invitation" FROM "internal_admin";

REVOKE TRUNCATE ON TABLE "public"."invitation" FROM "internal_admin";

REVOKE UPDATE ON TABLE "public"."invitation" FROM "internal_admin";

REVOKE DELETE ON TABLE "public"."invitee" FROM "internal_admin";

REVOKE INSERT ON TABLE "public"."invitee" FROM "internal_admin";

REVOKE REFERENCES ON TABLE "public"."invitee" FROM "internal_admin";

REVOKE SELECT ON TABLE "public"."invitee" FROM "internal_admin";

REVOKE TRIGGER ON TABLE "public"."invitee" FROM "internal_admin";

REVOKE TRUNCATE ON TABLE "public"."invitee" FROM "internal_admin";

REVOKE UPDATE ON TABLE "public"."invitee" FROM "internal_admin";

REVOKE DELETE ON TABLE "public"."organization" FROM "internal_admin";

REVOKE INSERT ON TABLE "public"."organization" FROM "internal_admin";

REVOKE REFERENCES ON TABLE "public"."organization" FROM "internal_admin";

REVOKE SELECT ON TABLE "public"."organization" FROM "internal_admin";

REVOKE TRIGGER ON TABLE "public"."organization" FROM "internal_admin";

REVOKE TRUNCATE ON TABLE "public"."organization" FROM "internal_admin";

REVOKE UPDATE ON TABLE "public"."organization" FROM "internal_admin";

REVOKE DELETE ON TABLE "public"."raw_event" FROM "internal_admin";

REVOKE INSERT ON TABLE "public"."raw_event" FROM "internal_admin";

REVOKE REFERENCES ON TABLE "public"."raw_event" FROM "internal_admin";

REVOKE SELECT ON TABLE "public"."raw_event" FROM "internal_admin";

REVOKE TRIGGER ON TABLE "public"."raw_event" FROM "internal_admin";

REVOKE TRUNCATE ON TABLE "public"."raw_event" FROM "internal_admin";

REVOKE UPDATE ON TABLE "public"."raw_event" FROM "internal_admin";

REVOKE DELETE ON TABLE "public"."user" FROM "internal_admin";

REVOKE INSERT ON TABLE "public"."user" FROM "internal_admin";

REVOKE REFERENCES ON TABLE "public"."user" FROM "internal_admin";

REVOKE SELECT ON TABLE "public"."user" FROM "internal_admin";

REVOKE TRIGGER ON TABLE "public"."user" FROM "internal_admin";

REVOKE TRUNCATE ON TABLE "public"."user" FROM "internal_admin";

REVOKE UPDATE ON TABLE "public"."user" FROM "internal_admin";

REVOKE DELETE ON TABLE "public"."waitlist" FROM "internal_admin";

REVOKE INSERT ON TABLE "public"."waitlist" FROM "internal_admin";

REVOKE REFERENCES ON TABLE "public"."waitlist" FROM "internal_admin";

REVOKE SELECT ON TABLE "public"."waitlist" FROM "internal_admin";

REVOKE TRIGGER ON TABLE "public"."waitlist" FROM "internal_admin";

REVOKE TRUNCATE ON TABLE "public"."waitlist" FROM "internal_admin";

REVOKE UPDATE ON TABLE "public"."waitlist" FROM "internal_admin";

DROP VIEW IF EXISTS "public"."sync_admin";

CREATE OR REPLACE VIEW "public"."sync_admin" AS
SELECT
    min(a.email) AS email,
    min(a.id) AS account_id,
    min(a.provider) AS provider,
    c.provider_id AS calendar_provider_id,
    c.created_at AS first_synced_at,
    c.full_sync_at,
    c.synced_at,
    c.sync_error AS error,
    CASE WHEN ((c.full_sync_at IS NULL)
        OR (c.sync_error IS NOT NULL)) THEN
        NULL::numeric
    ELSE
        round(EXTRACT(epoch FROM (COALESCE(c.full_sync_at, now()) - c.full_sync_started_at)))
    END AS sync_seconds,
    count(e.id) AS event_count
FROM ((account a
    LEFT JOIN calendar c ON (c.account_id = a.id))
    LEFT JOIN event e ON (e.calendar_id = c.id))
GROUP BY
    c.id;

REVOKE ALL ON sync_admin FROM PUBLIC;

GRANT SELECT ON sync_admin TO internal_admin;

