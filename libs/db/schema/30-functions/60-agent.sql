CREATE OR REPLACE FUNCTION agent_uuid()
    RETURNS uuid AS $$
    DECLARE
        random_bytes bytea;
        uuid_text text;
    BEGIN
        SELECT encode(gen_random_bytes(12), 'hex') INTO uuid_text;
        RETURN (
            uuid('ab07ab07' || '-' ||
            substring(uuid_text FROM 1 FOR 4) || '-' ||
            substring(uuid_text FROM 3 FOR 4) || '-' ||
            substring(uuid_text FROM 5 FOR 4) || '-' ||
            substring(uuid_text FROM 7 FOR 12))
        );
    END;
$$ LANGUAGE plpgsql;