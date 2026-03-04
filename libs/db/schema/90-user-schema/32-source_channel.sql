-- User-accessible source channels filtered by source account ownership
CREATE OR REPLACE VIEW "user"."source_channel" AS
SELECT
    pt.owner_id AS user_id,
    sc.*
FROM
    source_channel sc
    JOIN priority_twist pt ON pt.id = sc.priority_twist_id;
