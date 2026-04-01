-- Create "propagate_organization_id_to_descendants" function
CREATE FUNCTION "public"."propagate_organization_id_to_descendants" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.organization_id IS DISTINCT FROM OLD.organization_id THEN
        UPDATE
            public.priority
        SET
            organization_id = NEW.organization_id
        WHERE
            path <@ NEW.path
            AND path != NEW.path
            AND (organization_id IS DISTINCT FROM NEW.organization_id);
    END IF;
    RETURN NEW;
END;
$$;
-- Create trigger "priority_propagate_org_id_update"
CREATE TRIGGER "priority_propagate_org_id_update" AFTER UPDATE OF "organization_id" ON "public"."priority" FOR EACH ROW EXECUTE FUNCTION "public"."propagate_organization_id_to_descendants"();

-- Backfill: set organization_id on child priorities that inherited from a root with one set
UPDATE priority AS child
SET organization_id = root.organization_id
FROM priority AS root
WHERE root.path = subpath(child.path, 0, 1)
  AND root.organization_id IS NOT NULL
  AND child.organization_id IS NULL
  AND nlevel(child.path) > 1;
