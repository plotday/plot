-- Modify "classify_thread_for_user" function
CREATE OR REPLACE FUNCTION "public"."classify_thread_for_user" ("p_user_id" uuid, "p_thread_id" uuid DEFAULT NULL::uuid, "p_embedding" public.halfvec DEFAULT NULL::public.halfvec, "p_topic" text DEFAULT NULL::text, "p_contacts" uuid[] DEFAULT NULL::uuid[], "p_groups" uuid[] DEFAULT NULL::uuid[]) RETURNS uuid LANGUAGE sql STABLE AS $$
SELECT priority_id
    FROM public.classify_thread_for_user_explain(
        p_user_id,
        p_thread_id,
        p_embedding,
        p_topic,
        p_contacts,
        p_groups
    );
$$;
