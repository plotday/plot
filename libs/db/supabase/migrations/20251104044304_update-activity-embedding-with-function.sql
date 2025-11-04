SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.find_similar_activities (query_embedding text, created_by_id uuid, similarity_threshold double precision DEFAULT 0.5, match_limit integer DEFAULT 1)
    RETURNS TABLE (
        id uuid,
        priority_id uuid,
        title text,
        similarity double precision)
    LANGUAGE plpgsql
    AS $function$
BEGIN
    RETURN QUERY
    SELECT
        a.id,
        a.priority_id,
        a.title,
        1 - (a.embedding <=> query_embedding::vector) AS similarity
    FROM
        public.activity a
    WHERE
        a.created_by = created_by_id
        AND a.embedding IS NOT NULL
        AND a.deleted_at IS NULL
        AND (1 - (a.embedding <=> query_embedding::vector)) >= similarity_threshold
    ORDER BY
        a.embedding <=> query_embedding::vector
    LIMIT match_limit;
END;
$function$;

ALTER VIEW "public"."activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_children" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_exception" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "admin"."invitation" SET ( security_invoker = FALSE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_settings_inherited" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_agent" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
