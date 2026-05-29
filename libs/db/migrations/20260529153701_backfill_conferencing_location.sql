-- Backfill: collapse calendar videoconferencing links that were stored in
-- meta.location into a conferencing action, and clear the duplicate URL from
-- meta.location. Clients render a conferencing action as a single clickable
-- provider chip ("Zoom"); a location-that-is-a-URL renders as unclickable
-- text mislabelled as a physical location. This one-time backfill fixes
-- already-synced events without an app release.
--
-- Mirrors the server-side normalization in
-- workers/api/src/twist/tools/plot/conferencing.ts (applied on every future
-- sync). Scope is limited to rows where the ENTIRE location is a single
-- conferencing URL — the common case (e.g. a Zoom URL pasted into Google
-- Calendar's location field). Rarer mixed "Room 5, <url>" rows are left for
-- the API to normalize on their next sync, keeping this SQL safe and simple.
--
-- The UPDATE fires the set_link_updated_at BEFORE UPDATE trigger, which bumps
-- link.seq via pg_current_xact_id(), so the change propagates to clients
-- through the /sync/links seq cursor.
WITH detected AS (
    SELECT
        l.id,
        btrim(l.meta ->> 'location') AS url,
        CASE
        WHEN btrim(l.meta ->> 'location') ILIKE '%zoom.us%' THEN
            'zoom'
        WHEN btrim(l.meta ->> 'location') ILIKE '%teams.microsoft.com%'
            OR btrim(l.meta ->> 'location') ILIKE '%teams.live.com%' THEN
            'microsoftTeams'
        WHEN btrim(l.meta ->> 'location') ILIKE '%webex.com%' THEN
            'webex'
        WHEN btrim(l.meta ->> 'location') ILIKE '%meet.google.com%' THEN
            'googleMeet'
        END AS provider
    FROM
        link l
    WHERE
        l.meta ->> 'location' IS NOT NULL
        -- the entire location is a single URL (no surrounding text)
        AND btrim(l.meta ->> 'location') ~* '^https?://[^[:space:]]+$'
        AND btrim(l.meta ->> 'location') ~* '(zoom\.us|teams\.microsoft\.com|teams\.live\.com|webex\.com|meet\.google\.com)'
)
UPDATE
    link l
SET
    actions = CASE
    -- don't duplicate an action the connector already attached
    WHEN COALESCE(l.actions, '[]'::jsonb) @> jsonb_build_array(jsonb_build_object('type', 'conferencing', 'url', d.url)) THEN
        l.actions
    ELSE
        COALESCE(l.actions, '[]'::jsonb) || jsonb_build_array(jsonb_build_object('type', 'conferencing', 'url', d.url, 'provider', d.provider))
    END,
    -- drop the duplicate URL; nothing else lived in location for these rows
    meta = l.meta - 'location'
FROM
    detected d
WHERE
    l.id = d.id
    AND d.provider IS NOT NULL;
