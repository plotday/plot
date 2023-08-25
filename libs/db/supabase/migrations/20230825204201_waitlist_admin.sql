CREATE OR REPLACE VIEW "public"."invitation_admin" AS
SELECT
    min(i.id) AS id,
    min(i.created_at) AS created_at,
    min(i.code) AS code,
    min(i.remaining) AS remaining,
    count(u.invitation) AS uses
FROM (invitation i
    LEFT JOIN "user" u ON (u.invitation = i.code))
GROUP BY
    i.id;

REVOKE ALL ON invitation_admin FROM PUBLIC;

GRANT SELECT ON invitation_admin TO internal_admin;

CREATE OR REPLACE VIEW "public"."waitlist_admin" AS
SELECT
    min(w.id) AS id,
    min(w.created_at) AS created_at,
    min(w.email) AS email,
    min(a.created_at) AS account_created_at
FROM (waitlist w
    LEFT JOIN account a ON ((lower(a.email) = lower(w.email))))
GROUP BY
    w.id;

REVOKE ALL ON waitlist_admin FROM PUBLIC;

GRANT SELECT ON waitlist_admin TO internal_admin;

CREATE OR REPLACE VIEW "public"."sync_admin" AS
SELECT
    min(a.email) AS email,
    min(a.id) AS account_id,
    min(a.provider) AS provider,
    c.provider_id AS calendar_provider_id,
    c.created_at AS first_synced_at,
    c.full_sync_at,
    c.synced_at AS updated_at,
    c.sync_error AS error,
    CASE WHEN (c.full_sync_at IS NULL) THEN
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

