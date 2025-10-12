/**
 * Returns a time-ordered with Unix Epoch UUID (UUIDv7).
 * 
 * References:
 * - https://github.com/uuid6/uuid6-ietf-draft
 * - https://github.com/ietf-wg-uuidrev/rfc4122bis
 *
 * MIT License.
 *
 * Tags: uuid guid uuid-generator guid-generator generator time order rfc4122 rfc-4122
 */
CREATE OR REPLACE FUNCTION gen_random_uuid_v7 ()
    RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_time timestamp with time zone := NULL;
    v_secs bigint := NULL;
    v_msec bigint := NULL;
    v_usec bigint := NULL;
    v_timestamp bigint := NULL;
    v_timestamp_hex varchar := NULL;
    v_random bigint := NULL;
    v_random_hex varchar := NULL;
    v_bytes bytea;
    c_variant bit(64) := x'8000000000000000';
    -- RFC-4122 variant: b'10xx...'
BEGIN
    -- Get seconds and micros
    v_time := clock_timestamp();
    v_secs := EXTRACT(EPOCH FROM v_time);
    v_msec := mod(EXTRACT(MILLISECONDS FROM v_time)::numeric, 10 ^ 3::numeric);
    v_usec := mod(EXTRACT(MICROSECONDS FROM v_time)::numeric, 10 ^ 3::numeric);
    -- Generate timestamp hexadecimal (and set version 7)
    v_timestamp := (((v_secs * 10 ^ 3) + v_msec)::bigint << 12) | (v_usec << 2);
    v_timestamp_hex := lpad(to_hex(v_timestamp), 16, '0');
    v_timestamp_hex := substr(v_timestamp_hex, 2, 12) || '7' || substr(v_timestamp_hex, 14, 3);
    -- Generate the random hexadecimal (and set variant b'10xx')
    v_random := ((random()::numeric * 2 ^ 62::numeric)::bigint::bit(64) | c_variant)::bigint;
    v_random_hex := lpad(to_hex(v_random), 16, '0');
    -- Concat timestemp and random hexadecimal
    v_bytes := decode(v_timestamp_hex || v_random_hex, 'hex');
    RETURN encode(v_bytes, 'hex')::uuid;
END
$$;

