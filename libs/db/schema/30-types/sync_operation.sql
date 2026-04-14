-- Sync operation enum for twist_instance_sync to track creates vs updates separately
CREATE TYPE sync_operation AS ENUM ('create', 'update');
