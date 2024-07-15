CREATE OR REPLACE FUNCTION parent_path (p ltree)
    RETURNS ltree
    AS $$
BEGIN
    RETURN subpath (p, 0, nlevel (p) - 1);
END;
$$
LANGUAGE plpgsql
IMMUTABLE;

