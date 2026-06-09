-- Resolve a connection (twist_instance) to a coarse "org group" key used by the
-- classifier's origin signal so a user's work connections merge while unrelated
-- personal accounts do not. Evaluated LIVE (no stored column):
--   1. the connection owner's account-email domain, when that domain is NOT a
--      known freemail provider                                 -> 'domain:<d>'
--   2. else the owning team                                    -> 'team:<id>'
--   3. else (personal freemail account, or unresolvable)       -> NULL
--
-- The account email comes from twist_instance_connection.actor_id -> contact
-- for the owner's own connection. A domain counts as "freemail" only if it has
-- a public.domain row with freemail = true; any other resolvable domain is
-- treated as an org domain (org domains are usually absent from public.domain).
CREATE OR REPLACE FUNCTION public.connection_org_key (p_twist_instance_id uuid)
    RETURNS text
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT CASE
        WHEN acct.domain IS NOT NULL
             AND acct.domain <> ''
             AND NOT EXISTS (
                 SELECT 1 FROM public.domain d
                 WHERE d.name = acct.domain AND d.freemail
             )
            THEN 'domain:' || acct.domain
        WHEN ti.team_id IS NOT NULL
            THEN 'team:' || ti.team_id::text
        ELSE NULL
    END
    FROM public.twist_instance ti
    LEFT JOIN LATERAL (
        SELECT lower(split_part(c.email, '@', 2)) AS domain
        FROM public.twist_instance_connection tic
        JOIN public.contact c ON c.id = tic.actor_id
        WHERE tic.twist_instance_id = ti.id
          AND tic.user_id = ti.owner_id
          AND c.email IS NOT NULL
          AND position('@' IN c.email) > 0
        ORDER BY tic.connected_at DESC
        LIMIT 1
    ) acct ON TRUE
    WHERE ti.id = p_twist_instance_id;
$function$;

COMMENT ON FUNCTION public.connection_org_key IS 'Coarse org-group key for a connection (twist_instance): non-freemail account-email domain -> domain:<d>, else owning team -> team:<id>, else NULL. Used by classify_thread_for_user_explain as the L2 origin signal.';
