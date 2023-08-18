DROP VIEW IF EXISTS "public"."event_x";

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.label_stats (user_id bigint, during tstzrange)
    RETURNS TABLE (
        label_id bigint,
        name text,
        response event_response,
        instances integer,
        minutes integer)
    LANGUAGE plpgsql
    AS $function$
BEGIN
    RETURN query
    SELECT
        l.id AS label_id,
        l.name AS name,
        e.response,
        count(*) AS instances,
        sum(e.minutes) AS minutes
    FROM
        event_x e
        JOIN event_label le ON le.event_id = e.id
        JOIN label l ON le.label_id = l.id
    WHERE
        e.user_id = label_stats.user_id
        AND e.at && during
        AND e.status != 'cancelled'
    GROUP BY
        l.id,
        e.status,
        e.response;
END
$function$;

CREATE OR REPLACE VIEW "public"."event_x" AS
SELECT
    u.id AS user_id,
    min(e.id) AS id,
    e.name,
    e.at,
    min(e.calendar_id) AS calendar_id,
    min(e.provider_id) AS provider_id,
    min(e.series) AS series,
    min(e.created_at) AS created_at,
    min(e.status) AS status,
    min(e.provider_link) AS provider_link,
    min(e.summary) AS summary,
    min(e.description) AS description,
    min(e.visibility) AS visibility,
    min(e.availability) AS availability,
    min(e.conferencing_url) AS conferencing_url,
    min(e.organizer) AS organizer,
    min(i.response) FILTER (WHERE (ct.contact_user_id = u.id)) AS response,
(round((EXTRACT(epoch FROM (upper(e.at) - lower(e.at))) / (60)::numeric)))::integer AS minutes,
count(DISTINCT i.contact_id) FILTER (WHERE (i.response = 'accepted'::event_response)) AS attendee_count,
count(DISTINCT i.contact_id) AS invitee_count
FROM (((((event e
                    JOIN calendar c ON (e.calendar_id = c.id))
                JOIN account a ON (c.account_id = a.id))
            JOIN "user" u ON (a.user_id = u.id))
        JOIN invitee i ON (e.id = i.event_id))
    JOIN contact ct ON (i.contact_id = ct.id))
GROUP BY
    u.id,
    e.name,
    e.at;

CREATE POLICY "Users can view their own labels" ON "public"."event_label" AS permissive
    FOR ALL TO authenticated
        USING ((event_id IN (
            SELECT
                event.id
            FROM
                event)));

CREATE POLICY "Everyone can view global labels" ON "public"."label" AS permissive
    FOR ALL TO authenticated
        USING ((user_id IS NULL));

