SET ROLE "postgres";
SET check_function_bodies = false;
CREATE FUNCTION public.ensure_priority_user_contact()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
    INSERT INTO priority_contact (priority_id, contact_id)
    SELECT
        NEW.priority_id,
        c.id
    FROM
        contact c
    WHERE
        c.user_id = NEW.user_id
        AND c."primary" = TRUE
        AND c.archived_at IS NULL
    ON CONFLICT (priority_id, contact_id)
        DO NOTHING;
    RETURN NULL;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.ensure_priority_user_contact () FROM PUBLIC;

CREATE TRIGGER ensure_priority_user_contact_trigger AFTER INSERT ON public.priority_user FOR EACH ROW EXECUTE FUNCTION public.ensure_priority_user_contact();

CREATE OR REPLACE VIEW public.user_priority_actor WITH (security_invoker=true) AS SELECT user_id,
    priority_path,
    actor_id,
    created_at,
    updated_at,
    archived_at
   FROM ( SELECT upe.user_id,
            p.path AS priority_path,
            pc.contact_id AS actor_id,
            LEAST(COALESCE(pc.created_at, c.created_at), COALESCE(c.created_at, pc.created_at)) AS created_at,
            GREATEST(pc.updated_at, c.updated_at) AS updated_at,
                CASE
                    WHEN ((pc.invited_by IS NOT NULL) AND (pc.invited_at IS NULL)) THEN pc.updated_at
                    ELSE c.archived_at
                END AS archived_at
           FROM (((public.user_priority_expanded upe
             JOIN public.priority_contact pc ON ((pc.priority_id = upe.priority_id)))
             JOIN public.contact c ON ((c.id = pc.contact_id)))
             JOIN public.priority p ON ((p.id = pc.priority_id)))
        UNION ALL
         SELECT upe.user_id,
            p.path AS priority_path,
            pt.id AS actor_id,
            pt.created_at,
            pt.updated_at,
            pt.archived_at
           FROM ((public.user_priority_expanded upe
             JOIN public.priority_twist pt ON ((pt.priority_id = upe.priority_id)))
             JOIN public.priority p ON ((p.id = pt.priority_id)))) actors;

-- Backfill: create priority_contact entries for existing priority_user entries
-- that don't have a corresponding priority_contact
INSERT INTO priority_contact (priority_id, contact_id)
SELECT DISTINCT pu.priority_id, c.id
FROM priority_user pu
JOIN contact c ON c.user_id = pu.user_id AND c."primary" = TRUE AND c.archived_at IS NULL
WHERE pu.archived_at IS NULL
  AND NOT EXISTS (
    SELECT 1 FROM priority_contact pc
    WHERE pc.priority_id = pu.priority_id AND pc.contact_id = c.id
  )
ON CONFLICT (priority_id, contact_id) DO NOTHING;
