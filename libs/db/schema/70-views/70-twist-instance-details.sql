-- All active twist_instances enriched with twist metadata and publisher info.
CREATE OR REPLACE VIEW "public"."twist_instance_details" -- for formatting
AS
SELECT
    pt.*,
    t.version,
    t.environment AS twist_environment,
    t.is_source,
    p.name AS author_name,
    p.email AS author_email,
    p.url AS author_url
FROM
    twist_instance pt
    JOIN twist t ON pt.twist_id = t.id
    LEFT JOIN publisher p ON t.publisher_id = p.id
WHERE
    pt.archived_at IS NULL;
