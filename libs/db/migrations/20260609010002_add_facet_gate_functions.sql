-- Create "author_matches_org_domain" function
CREATE FUNCTION "public"."author_matches_org_domain" ("p_user_id" uuid, "p_author_id" uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
WITH author_domain AS (
        SELECT lower(split_part(c.email, '@', 2)) AS dom
        FROM public.contact c
        WHERE c.id = p_author_id AND c.email IS NOT NULL
    ),
    user_domains AS (
        SELECT DISTINCT lower(split_part(c.email, '@', 2)) AS dom
        FROM public.user_contact uc
        JOIN public.contact c ON c.id = uc.contact_id
        WHERE uc.user_id = p_user_id
          AND uc.linked = TRUE
          AND uc.archived_at IS NULL
          AND c.email IS NOT NULL
    )
    SELECT EXISTS (
        SELECT 1
        FROM author_domain ad
        JOIN user_domains ud ON ud.dom = ad.dom
        WHERE ad.dom <> ''
          AND NOT EXISTS (
              SELECT 1 FROM public.domain d
              WHERE d.name = ad.dom AND d.freemail = TRUE
          )
    );
$$;
-- Set comment to function: "author_matches_org_domain"
COMMENT ON FUNCTION "public"."author_matches_org_domain" IS 'True if author email domain matches the user''s own linked identity domain, excluding freemail hosts (public.domain.freemail).';
-- Create "intrinsic_facets_violate" function
CREATE FUNCTION "public"."intrinsic_facets_violate" ("p_facets" jsonb, "p_filters" jsonb) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
SELECT COALESCE((
        SELECT bool_or(
            -- exclude violation: known value is in the exclude set
            (
                p_filters -> dims.dim ? 'exclude'
                AND p_facets ->> dims.dim IS NOT NULL
                AND p_facets ->> dims.dim IN (
                    SELECT jsonb_array_elements_text(p_filters -> dims.dim -> 'exclude')
                )
            )
            OR
            -- include violation: include set present, value known, not included
            (
                p_filters -> dims.dim ? 'include'
                AND p_facets ->> dims.dim IS NOT NULL
                AND p_facets ->> dims.dim NOT IN (
                    SELECT jsonb_array_elements_text(p_filters -> dims.dim -> 'include')
                )
            )
        )
        FROM (VALUES ('format'), ('automation'), ('reach')) AS dims(dim)
    ), FALSE);
$$;
-- Set comment to function: "intrinsic_facets_violate"
COMMENT ON FUNCTION "public"."intrinsic_facets_violate" IS 'True if a thread''s format/automation/reach facets violate a focus''s include/exclude filters. Fail-open on null facet values.';
-- Create "is_trusted_for_focus" function
CREATE FUNCTION "public"."is_trusted_for_focus" ("p_user_id" uuid, "p_author_id" uuid, "p_priority_id" uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
SELECT p_author_id IS NOT NULL AND EXISTS (
        SELECT 1
        FROM public.thread_priority tp
        JOIN public.thread t ON t.id = tp.thread_id
        WHERE tp.user_id = p_user_id
          AND tp.priority_id = p_priority_id
          AND (tp.user_moved = TRUE OR t.created_by = p_user_id)
          AND p_author_id = ANY(t.contacts)
    );
$$;
-- Set comment to function: "is_trusted_for_focus"
COMMENT ON FUNCTION "public"."is_trusted_for_focus" IS 'True if the author participates in a thread the user moved into / composed in this focus (per-focus trusted sender).';
-- Create "thread_facets_gated" function
CREATE FUNCTION "public"."thread_facets_gated" ("p_user_id" uuid, "p_facets" jsonb, "p_author_id" uuid, "p_priority_id" uuid) RETURNS boolean LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_filters jsonb;
    v_trusted_focus boolean;
BEGIN
    SELECT facet_filters INTO v_filters FROM public.priority WHERE id = p_priority_id;
    IF v_filters IS NULL THEN
        RETURN FALSE;
    END IF;

    v_trusted_focus := public.is_trusted_for_focus(p_user_id, p_author_id, p_priority_id);

    -- Intrinsic gate, bypassed by a trusted-for-focus author.
    IF NOT v_trusted_focus AND public.intrinsic_facets_violate(p_facets, v_filters) THEN
        RETURN TRUE;
    END IF;

    -- Trust filter.
    IF COALESCE((v_filters ->> 'trustedSendersOnly')::boolean, FALSE)
       AND NOT (v_trusted_focus OR public.author_matches_org_domain(p_user_id, p_author_id)) THEN
        RETURN TRUE;
    END IF;

    RETURN FALSE;
END;
$$;
-- Set comment to function: "thread_facets_gated"
COMMENT ON FUNCTION "public"."thread_facets_gated" IS 'True if a thread is excluded from a focus by facet filters. Bypassed for per-focus trusted senders; trustedSendersOnly admits trusted-for-focus or org-domain authors.';
