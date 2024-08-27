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

CREATE OR REPLACE FUNCTION replace_parent_path (parent_path ltree, child_path ltree, new_parent_path ltree)
    RETURNS ltree
    AS $$
BEGIN
    IF child_path = parent_path THEN
        RETURN new_parent_path;
    ELSIF child_path <@ parent_path THEN
        RETURN new_parent_path || subpath (child_path, nlevel (parent_path));
    ELSE
        RETURN child_path;
    END IF;
END;
$$
LANGUAGE plpgsql;

