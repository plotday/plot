-- Fix event_x view to use LEFT JOIN instead of JOIN for calendar
-- This allows events without calendar_id to be included in the view

CREATE OR REPLACE VIEW "public"."event_x" WITH ( security_invoker = TRUE)
-- for formatting
AS
WITH event_x1 AS (
    SELECT
        e.id AS id,
        e.user_id AS user_id,
        e.name,
        (
            CASE WHEN calc_all_day (e.at) THEN
                tstzrange(timezone(user_timezone (), timezone('UTC', lower(e.at))), timezone(user_timezone (), timezone('UTC', upper(e.at))), '[)'::text)
            ELSE
                e.at
            END) AS at,
        c.account_id AS account_id,
        e.calendar_id AS calendar_id,
        e.provider_id AS provider_id,
        COALESCE(e.series, e.provider_id) AS series,
        e.created_at AS created_at,
        GREATEST (e.updated_at, i.updated_at) AS updated_at,
        GREATEST (e.deleted_at, i.deleted_at) AS deleted_at,
        e.draft AS draft,
        e.status AS status,
        e.provider_link AS provider_link,
        e.summary AS summary,
        e.description AS description,
        e.visibility AS visibility,
        e.availability AS availability,
        e.conferencing_url AS conferencing_url,
        e.organizer_email AS organizer_email,
        e.response AS response,
        calc_seconds (e.at) AS seconds,
        CASE WHEN EXTRACT(epoch FROM (upper(e.at) - lower(e.at))) >= 60 * 60 * 23 THEN
            timezone(user_timezone (), timezone('UTC', lower(e.at)))::date
        ELSE
            (lower(e.at) at time zone user_timezone ())::date
        END AS day,
        a.email = e.organizer_email AS initiated,
        calc_all_day (e.at) AS all_day,
        calc_event_type (e.at, e.availability, COALESCE(e.response, 'tentative'), i.invitee_count > 1
            OR e.invitees_hidden) AS type,
        d.organization_id IS NOT NULL
        AND (i.freemail_invitees
            OR NOT (d.organization_id = ALL (i.invitee_organization_ids))) AS external,
        e.invitees_hidden AS invitees_hidden,
        e.series IS NOT NULL AS recurring,
        calc_notice (e.created_at, e.at) AS notice,
        calc_speedy (e.at) AS speedy,
        calc_rounded_length (e.at) AS rounded_length,
        s.embedding AS embedding,
        i.attendee_count AS attendee_count,
        i.invitee_count AS invitee_count,
        i.invitees AS invitees,
        i.invitee_domains AS invitee_domains,
        i.size AS size
    FROM
        event e
        LEFT OUTER JOIN calendar c ON (e.calendar_id = c.id)
        LEFT OUTER JOIN account a ON (c.account_id = a.id)
        LEFT OUTER JOIN "domain" d ON (d.name = get_domain (a.email))
        LEFT OUTER JOIN "series" s ON (s.user_id = e.user_id
                AND s.series = e.series)
        LEFT OUTER JOIN event_invitees i ON (e.id = i.event_id)
    WHERE
        e.calendar_id IS NULL
        OR c.enabled = TRUE
)
SELECT
    e.*,
    ctx.id AS priority_id,
    ctx.path AS priority_path
FROM
    event_x1 e
    LEFT JOIN calendar c ON c.id = e.calendar_id
    LEFT JOIN LATERAL (
        SELECT
            priority_id
        FROM
            series
        WHERE
            user_id = e.user_id
            AND priority_id IS NOT NULL
        ORDER BY
            series = e.series DESC,
            invitees = e.invitees DESC,
            embedding <-> e.embedding DESC
        LIMIT 1) AS s ON TRUE
    LEFT JOIN priority ctx ON ctx.id = COALESCE(s.priority_id, c.priority_id);