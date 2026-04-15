-- Restore public-environment twist rows for all publisher connectors.
--
-- Root cause: The 20260414233031_single_root_priorities migration Step 5 deleted
-- sub-priorities under @plot.twist-dev via CASCADE. Because twist_admin.priority_id
-- references priority ON DELETE CASCADE, and twist.twist_admin_id references
-- twist_admin ON DELETE CASCADE, all twist rows were cascade-deleted along with those
-- sub-priorities.
--
-- Subsequent connector deployments recreated twist_admin rows (now pointing directly
-- to @plot.twist-dev instead of sub-priorities) and review-environment twist rows,
-- but did NOT recreate the public-environment rows. This left zero public-environment
-- twists in production, making all public connectors invisible to users.
--
-- Fix: promote all current review-environment publisher twists to public by inserting
-- corresponding public-environment rows. The review rows are the authoritative source
-- for all metadata (name, version, permissions, etc.).

INSERT INTO twist (twist_admin_id, environment, name, description, version, permissions,
                   options_schema, is_source, shared, key_option, logo_url, logo_url_dark, execution_limit)
SELECT
    t.twist_admin_id,
    'public'::twist_environment,
    t.name,
    t.description,
    t.version,
    t.permissions,
    t.options_schema,
    t.is_source,
    t.shared,
    t.key_option,
    t.logo_url,
    t.logo_url_dark,
    t.execution_limit
FROM twist t
JOIN twist_admin ta ON ta.id = t.twist_admin_id
WHERE t.environment = 'review'
  AND t.archived_at IS NULL
  AND ta.publisher_id IS NOT NULL
ON CONFLICT (twist_admin_id, environment) DO NOTHING;
