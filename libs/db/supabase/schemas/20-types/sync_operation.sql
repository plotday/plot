-- Sync operation enum for priority_twist_sync to track creates vs updates separately
CREATE TYPE sync_operation AS ENUM ('create', 'update');
