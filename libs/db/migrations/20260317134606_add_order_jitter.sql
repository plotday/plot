-- Modify "order_first" function
CREATE OR REPLACE FUNCTION "public"."order_first" () RETURNS double precision LANGUAGE plpgsql AS $$
DECLARE
    millis_since_epoch double precision;
BEGIN
    millis_since_epoch := EXTRACT(epoch FROM CURRENT_TIMESTAMP) * 1000;
    RETURN millis_since_epoch + random();
END;
$$;
