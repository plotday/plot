-- Modify "user_contact_id" function
CREATE OR REPLACE FUNCTION "user"."user_contact_id" ("p_user_id" uuid) RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT c.id FROM contact c WHERE c.user_id = p_user_id AND c."primary" = TRUE LIMIT 1; $$;
