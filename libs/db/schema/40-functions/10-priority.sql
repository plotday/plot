CREATE OR REPLACE FUNCTION parent_path (p ltree)
    RETURNS ltree
    AS $$
BEGIN
    IF nlevel (p) = 1 THEN
        RETURN p;
    END IF;
    RETURN subpath (p, 0, nlevel (p) - 1);
END;
$$
LANGUAGE plpgsql
IMMUTABLE;

CREATE OR REPLACE FUNCTION generate_path (parent ltree DEFAULT NULL)
    RETURNS ltree
    AS $$
DECLARE
    characters text := 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    random_path text := '';
    prefix text := '';
    random_int integer;
    len integer;
BEGIN
    IF parent IS NOT NULL THEN
        prefix := ltree2text (parent) || '.';
        len := 4;
    ELSE
        len := 12;
    END IF;
    FOR i IN 1..len LOOP
        random_int := floor(random() * length(characters))::integer + 1;
        random_path := random_path || substr(characters, random_int, 1);
    END LOOP;
    RETURN text2ltree (prefix || random_path);
END;
$$
LANGUAGE plpgsql
VOLATILE;

CREATE OR REPLACE FUNCTION order_first ()
    RETURNS double precision
    AS $$
DECLARE
    millis_since_epoch double precision;
BEGIN
    millis_since_epoch := EXTRACT(epoch FROM CURRENT_TIMESTAMP) * 1000;
    RETURN millis_since_epoch + random();
END;
$$
LANGUAGE plpgsql;

