-- User-accessible source channels filtered by source account ownership
CREATE OR REPLACE VIEW "user"."channel" AS
SELECT
    pt.owner_id AS user_id,
    sc.*
FROM
    channel sc
    JOIN twist_instance pt ON pt.id = sc.twist_instance_id;
