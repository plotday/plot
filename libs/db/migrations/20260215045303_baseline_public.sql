--
-- PostgreSQL database dump
--


-- Dumped from database version 17.6
-- Dumped by pg_dump version 17.8 (Homebrew)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: gen_random_uuid_v7(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.gen_random_uuid_v7() RETURNS uuid
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


ALTER FUNCTION public.gen_random_uuid_v7() OWNER TO postgres;

--
-- Name: order_first(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.order_first() RETURNS double precision
    LANGUAGE plpgsql
    AS $$
DECLARE
    millis_since_epoch double precision;
BEGIN
    millis_since_epoch := EXTRACT(epoch FROM CURRENT_TIMESTAMP) * 1000;
    RETURN millis_since_epoch;
END;
$$;


ALTER FUNCTION public.order_first() OWNER TO postgres;

--
-- Name: generate_path(public.ltree); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.generate_path(parent public.ltree DEFAULT NULL::public.ltree) RETURNS public.ltree
    LANGUAGE plpgsql
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
$$;


ALTER FUNCTION public.generate_path(parent public.ltree) OWNER TO postgres;

--
-- Name: is_finite(tstzrange); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.is_finite(test tstzrange) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE
    AS $$
BEGIN
    RETURN NOT (lower_inf(test)
        OR upper_inf(test));
END;
$$;


ALTER FUNCTION public.is_finite(test tstzrange) OWNER TO postgres;

--
-- Name: is_lower(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.is_lower(text) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE
    AS $_$
BEGIN
    RETURN $1 = lower($1);
END;
$_$;


ALTER FUNCTION public.is_lower(text) OWNER TO postgres;

--
-- Name: parent_path(public.ltree); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.parent_path(p public.ltree) RETURNS public.ltree
    LANGUAGE plpgsql IMMUTABLE
    AS $$
BEGIN
    IF nlevel (p) = 1 THEN
        RETURN p;
    END IF;
    RETURN subpath (p, 0, nlevel (p) - 1);
END;
$$;


ALTER FUNCTION public.parent_path(p public.ltree) OWNER TO postgres;

--
-- Name: activity_kind; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.activity_kind AS ENUM (
    'document',
    'messages',
    'meeting',
    'videoconference',
    'phone',
    'focus',
    'meal',
    'exercise',
    'family',
    'travel',
    'social',
    'entertainment'
);


ALTER TYPE public.activity_kind OWNER TO postgres;

--
-- Name: activity_type; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.activity_type AS ENUM (
    'action',
    'event',
    'note'
);


ALTER TYPE public.activity_type OWNER TO postgres;

--
-- Name: contact_upsert; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.contact_upsert AS (
	calendar_id bigint,
	email text,
	name text,
	avatar_url text
);


ALTER TYPE public.contact_upsert OWNER TO postgres;

--
-- Name: enter_behavior; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.enter_behavior AS ENUM (
    'enter_newline',
    'enter_submits'
);


ALTER TYPE public.enter_behavior OWNER TO postgres;

--
-- Name: subscription_plan; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.subscription_plan AS ENUM (
    'free'
);


ALTER TYPE public.subscription_plan OWNER TO postgres;

--
-- Name: subscription_status; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.subscription_status AS ENUM (
    'active',
    'canceled',
    'past_due',
    'trialing',
    'incomplete',
    'incomplete_expired',
    'unpaid'
);


ALTER TYPE public.subscription_status OWNER TO postgres;

--
-- Name: sync_operation; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.sync_operation AS ENUM (
    'create',
    'update'
);


ALTER TYPE public.sync_operation OWNER TO postgres;

--
-- Name: tag_type; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.tag_type AS ENUM (
    'toggle',
    'count',
    'compute'
);


ALTER TYPE public.tag_type OWNER TO postgres;

--
-- Name: twist_environment; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.twist_environment AS ENUM (
    'personal',
    'private',
    'review',
    'public'
);


ALTER TYPE public.twist_environment OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: activity; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.activity (
    id uuid DEFAULT public.gen_random_uuid_v7() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    author_id uuid NOT NULL,
    created_by uuid NOT NULL,
    assignee_id uuid,
    updated_by integer DEFAULT 0 NOT NULL,
    archived_at timestamp with time zone,
    priority_id uuid NOT NULL,
    type public.activity_type DEFAULT 'note'::public.activity_type NOT NULL,
    "order" double precision DEFAULT public.order_first() NOT NULL,
    draft boolean DEFAULT false NOT NULL,
    private boolean DEFAULT false NOT NULL,
    title text,
    preview text,
    at tstzrange,
    "on" daterange,
    duration interval,
    done_at timestamp with time zone,
    recurrence_rule text,
    recurrence_exdates timestamp with time zone[],
    meta jsonb,
    source text,
    created_by_twist_id bigint,
    embedding public.halfvec(384),
    pick_priority jsonb,
    last_note_created_at timestamp with time zone,
    source_created_at timestamp with time zone DEFAULT now() NOT NULL,
    source_priority_root public.ltree,
    sync_depth integer,
    last_note_source_created_at timestamp with time zone,
    kind public.activity_kind,
    CONSTRAINT activity_action_assignee CHECK (((type <> 'action'::public.activity_type) OR (assignee_id IS NOT NULL) OR ((at IS NULL) AND ("on" IS NULL)))),
    CONSTRAINT activity_done_requires_action CHECK (((done_at IS NULL) OR (type = 'action'::public.activity_type))),
    CONSTRAINT activity_no_complete_recurrence CHECK (((recurrence_rule IS NULL) OR (done_at IS NULL))),
    CONSTRAINT activity_recurrence_on_or_at CHECK (((recurrence_rule IS NULL) OR (at IS NOT NULL) OR ("on" IS NOT NULL))),
    CONSTRAINT activity_scheduled CHECK ((((recurrence_rule IS NULL) AND (type <> 'event'::public.activity_type)) OR (at IS NOT NULL) OR ("on" IS NOT NULL))),
    CONSTRAINT activity_single_schedule CHECK (((at IS NULL) OR ("on" IS NULL))),
    CONSTRAINT activity_title_required_when_not_draft CHECK (((draft = true) OR ((title IS NOT NULL) AND (title <> ''::text))))
);


ALTER TABLE public.activity OWNER TO postgres;

--
-- Name: contact; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.contact (
    id uuid DEFAULT public.gen_random_uuid_v7() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    archived_at timestamp with time zone,
    email text NOT NULL,
    name text,
    avatar_url text,
    user_id uuid,
    "primary" boolean DEFAULT false NOT NULL,
    CONSTRAINT contact_email_check CHECK ((email = lower(email))),
    CONSTRAINT contact_primary_requires_user CHECK (((NOT "primary") OR (user_id IS NOT NULL)))
);


ALTER TABLE public.contact OWNER TO postgres;

--
-- Name: priority_twist; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.priority_twist (
    id uuid DEFAULT public.gen_random_uuid_v7() NOT NULL,
    priority_id uuid NOT NULL,
    twist_id bigint NOT NULL,
    owner_id uuid NOT NULL,
    name text NOT NULL,
    config jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    archived_at timestamp with time zone
);


ALTER TABLE public.priority_twist OWNER TO postgres;

--
-- Name: priority; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.priority (
    id uuid DEFAULT public.gen_random_uuid_v7() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid NOT NULL,
    archived_at timestamp with time zone,
    title text NOT NULL,
    color integer,
    path public.ltree NOT NULL,
    updated_by integer DEFAULT 0 NOT NULL,
    sync_depth integer,
    key text
);


ALTER TABLE public.priority OWNER TO postgres;

--
-- Name: note; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.note (
    id uuid DEFAULT public.gen_random_uuid_v7() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    author_id uuid NOT NULL,
    created_by uuid NOT NULL,
    updated_by integer DEFAULT 0 NOT NULL,
    archived_at timestamp with time zone,
    activity_id uuid NOT NULL,
    draft boolean DEFAULT false NOT NULL,
    private boolean DEFAULT false NOT NULL,
    content text,
    links jsonb,
    mentions uuid[],
    source_created_at timestamp with time zone DEFAULT now() NOT NULL,
    key text,
    sync_depth integer,
    re_note_id uuid
);


ALTER TABLE public.note OWNER TO postgres;

--
-- Name: activity_read; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.activity_read (
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    user_id uuid NOT NULL,
    activity_id uuid NOT NULL,
    read_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.activity_read OWNER TO postgres;

--
-- Name: priority_settings; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.priority_settings (
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    user_id uuid NOT NULL,
    priority_id uuid NOT NULL,
    top_order double precision,
    path public.ltree,
    pomodoro integer,
    color integer,
    "order" double precision,
    title text
);


ALTER TABLE public.priority_settings OWNER TO postgres;

--
-- Name: priority_user; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.priority_user (
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    user_id uuid NOT NULL,
    priority_id uuid NOT NULL,
    archived_at timestamp with time zone,
    personal boolean DEFAULT false NOT NULL
);


ALTER TABLE public.priority_user OWNER TO postgres;

--
-- Name: twist; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.twist (
    id bigint NOT NULL,
    twist_admin_id bigint NOT NULL,
    environment public.twist_environment DEFAULT 'personal'::public.twist_environment NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    archived_at timestamp with time zone,
    name text NOT NULL,
    description text,
    version text NOT NULL,
    permissions jsonb
);


ALTER TABLE public.twist OWNER TO postgres;

--
-- Name: organization; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.organization (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    name text NOT NULL
);


ALTER TABLE public.organization OWNER TO postgres;

--
-- Name: activity_exception; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.activity_exception (
    id uuid DEFAULT public.gen_random_uuid_v7() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by integer DEFAULT 0 NOT NULL,
    archived_at timestamp with time zone,
    activity_id uuid NOT NULL,
    occurrence text NOT NULL,
    at tstzrange,
    "on" daterange,
    duration interval,
    done_at timestamp with time zone,
    title text,
    meta jsonb,
    preview text
);


ALTER TABLE public.activity_exception OWNER TO postgres;

--
-- Name: activity_tag; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.activity_tag (
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    archived_at timestamp with time zone,
    actor_id uuid NOT NULL,
    activity_id uuid NOT NULL,
    occurrence text,
    tag_id integer NOT NULL,
    updated_by integer DEFAULT 0 NOT NULL,
    sync_depth integer,
    id bigint NOT NULL
);


ALTER TABLE public.activity_tag OWNER TO postgres;

--
-- Name: activity_tag_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.activity_tag ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.activity_tag_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: contact_external_account; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.contact_external_account (
    contact_id uuid NOT NULL,
    provider text NOT NULL,
    account_id text NOT NULL,
    data_fetched_at timestamp with time zone DEFAULT now() NOT NULL,
    last_reported_at timestamp with time zone
);


ALTER TABLE public.contact_external_account OWNER TO postgres;

--
-- Name: contact_invitation; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.contact_invitation (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    contact_id uuid NOT NULL,
    token text NOT NULL,
    sent_at timestamp with time zone DEFAULT now() NOT NULL,
    redeemed_at timestamp with time zone,
    redeemed_by uuid
);


ALTER TABLE public.contact_invitation OWNER TO postgres;

--
-- Name: contact_invitation_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.contact_invitation ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.contact_invitation_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: cost; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.cost (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    name text NOT NULL,
    start timestamp with time zone NOT NULL,
    amount numeric
);


ALTER TABLE public.cost OWNER TO postgres;

--
-- Name: cost_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.cost ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.cost_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: domain; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.domain (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    name text NOT NULL,
    organization_id bigint,
    CONSTRAINT domain_name_check CHECK ((name = lower(name)))
);


ALTER TABLE public.domain OWNER TO postgres;

--
-- Name: domain_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.domain ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.domain_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: note_tag; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.note_tag (
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    archived_at timestamp with time zone,
    actor_id uuid NOT NULL,
    note_id uuid NOT NULL,
    tag_id integer NOT NULL,
    updated_by integer DEFAULT 0 NOT NULL,
    sync_depth integer,
    id bigint NOT NULL
);


ALTER TABLE public.note_tag OWNER TO postgres;

--
-- Name: note_tag_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.note_tag ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.note_tag_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: organization_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.organization ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.organization_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: publisher; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.publisher (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    name text NOT NULL,
    email text,
    url text
);


ALTER TABLE public.publisher OWNER TO postgres;

--
-- Name: twist_admin; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.twist_admin (
    id bigint NOT NULL,
    twist_package_id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    publisher_id bigint,
    priority_id uuid,
    auto_approve boolean DEFAULT false NOT NULL,
    CONSTRAINT twist_admin_ownership_check CHECK ((((publisher_id IS NOT NULL) AND (user_id IS NULL)) OR ((publisher_id IS NULL) AND (user_id IS NOT NULL))))
);


ALTER TABLE public.twist_admin OWNER TO postgres;

--
-- Name: priority_contact; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.priority_contact (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    priority_id uuid NOT NULL,
    contact_id uuid NOT NULL,
    invited_by uuid,
    invited_at timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.priority_contact OWNER TO postgres;

--
-- Name: priority_contact_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.priority_contact ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.priority_contact_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: priority_twist_sync; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.priority_twist_sync (
    priority_twist_id uuid NOT NULL,
    entity text NOT NULL,
    last_update_at timestamp with time zone NOT NULL,
    last_sync_at timestamp with time zone DEFAULT '1970-01-01 00:00:00+00'::timestamp with time zone NOT NULL,
    operation public.sync_operation NOT NULL
);


ALTER TABLE public.priority_twist_sync OWNER TO postgres;

--
-- Name: publisher_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.publisher ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.publisher_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: series; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.series (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    user_id uuid NOT NULL,
    series text NOT NULL,
    invitees text[],
    embedding public.vector(384),
    priority_id uuid
);


ALTER TABLE public.series OWNER TO postgres;

--
-- Name: series_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.series ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.series_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: session; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.session (
    id uuid DEFAULT public.gen_random_uuid_v7() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    archived_at timestamp with time zone,
    user_id uuid NOT NULL,
    priority_id uuid,
    at tstzrange NOT NULL,
    precedence smallint DEFAULT 0 NOT NULL,
    pomodoro smallint,
    pomodoro_at timestamp with time zone,
    updated_by integer DEFAULT 0 NOT NULL,
    CONSTRAINT session_at_check CHECK ((NOT (lower_inf(at) OR upper_inf(at)))),
    CONSTRAINT session_pomodoro_check CHECK (((pomodoro IS NULL) OR (pomodoro > 0)))
);


ALTER TABLE public.session OWNER TO postgres;

--
-- Name: token; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.token (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    archived_at timestamp with time zone,
    user_id uuid,
    publisher_id bigint,
    token text NOT NULL,
    name text,
    last_used_at timestamp with time zone,
    CONSTRAINT token_owner_check CHECK (((((user_id IS NOT NULL))::integer + ((publisher_id IS NOT NULL))::integer) = 1))
);


ALTER TABLE public.token OWNER TO postgres;

--
-- Name: twist_admin_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.twist_admin ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.twist_admin_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: twist_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.twist ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.twist_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: usage; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.usage (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    priority_twist_id uuid NOT NULL,
    hour timestamp with time zone NOT NULL,
    cost_id bigint NOT NULL,
    amount integer NOT NULL,
    CONSTRAINT usage_hour_check CHECK ((hour = date_trunc('hour'::text, hour)))
);


ALTER TABLE public.usage OWNER TO postgres;

--
-- Name: usage_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.usage ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.usage_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: user; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public."user" (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    clerk_id text,
    email text NOT NULL,
    name text,
    avatar_url text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public."user" OWNER TO postgres;

--
-- Name: user_settings; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.user_settings (
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    user_id uuid NOT NULL,
    enter_behavior public.enter_behavior
);


ALTER TABLE public.user_settings OWNER TO postgres;

--
-- Name: user_subscription; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.user_subscription (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    user_id uuid NOT NULL,
    stripe_customer_id text,
    stripe_subscription_id text,
    plan public.subscription_plan DEFAULT 'free'::public.subscription_plan NOT NULL,
    status public.subscription_status DEFAULT 'active'::public.subscription_status NOT NULL,
    billing_cycle_start timestamp with time zone NOT NULL,
    billing_cycle_end timestamp with time zone NOT NULL
);


ALTER TABLE public.user_subscription OWNER TO postgres;

--
-- Name: user_subscription_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.user_subscription ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.user_subscription_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: user_sync; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.user_sync (
    user_id uuid NOT NULL,
    entity text NOT NULL,
    last_update_at timestamp with time zone NOT NULL,
    last_sync_at timestamp with time zone DEFAULT '1970-01-01 00:00:00+00'::timestamp with time zone NOT NULL
);


ALTER TABLE public.user_sync OWNER TO postgres;

--
-- Name: activity_exception activity_exception_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.activity_exception
    ADD CONSTRAINT activity_exception_pkey PRIMARY KEY (id);


--
-- Name: activity activity_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.activity
    ADD CONSTRAINT activity_pkey PRIMARY KEY (id);


--
-- Name: activity_read activity_read_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.activity_read
    ADD CONSTRAINT activity_read_pkey PRIMARY KEY (user_id, activity_id);


--
-- Name: activity_tag activity_tag_actor_id_activity_id_occurrence_tag_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.activity_tag
    ADD CONSTRAINT activity_tag_actor_id_activity_id_occurrence_tag_id_key UNIQUE NULLS NOT DISTINCT (actor_id, activity_id, occurrence, tag_id);


--
-- Name: activity_tag activity_tag_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.activity_tag
    ADD CONSTRAINT activity_tag_pkey PRIMARY KEY (id);


--
-- Name: contact contact_email_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.contact
    ADD CONSTRAINT contact_email_unique UNIQUE (email);


--
-- Name: contact_external_account contact_external_account_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.contact_external_account
    ADD CONSTRAINT contact_external_account_pkey PRIMARY KEY (provider, account_id);


--
-- Name: contact_invitation contact_invitation_contact_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.contact_invitation
    ADD CONSTRAINT contact_invitation_contact_unique UNIQUE (contact_id);


--
-- Name: contact_invitation contact_invitation_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.contact_invitation
    ADD CONSTRAINT contact_invitation_pkey PRIMARY KEY (id);


--
-- Name: contact_invitation contact_invitation_token_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.contact_invitation
    ADD CONSTRAINT contact_invitation_token_key UNIQUE (token);


--
-- Name: contact contact_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.contact
    ADD CONSTRAINT contact_pkey PRIMARY KEY (id);


--
-- Name: cost cost_name_start_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.cost
    ADD CONSTRAINT cost_name_start_key UNIQUE (name, start);


--
-- Name: cost cost_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.cost
    ADD CONSTRAINT cost_pkey PRIMARY KEY (id);


--
-- Name: domain domain_name_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.domain
    ADD CONSTRAINT domain_name_key UNIQUE (name);


--
-- Name: domain domain_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.domain
    ADD CONSTRAINT domain_pkey PRIMARY KEY (id);


--
-- Name: note note_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.note
    ADD CONSTRAINT note_pkey PRIMARY KEY (id);


--
-- Name: note_tag note_tag_actor_id_note_id_tag_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.note_tag
    ADD CONSTRAINT note_tag_actor_id_note_id_tag_id_key UNIQUE NULLS NOT DISTINCT (actor_id, note_id, tag_id);


--
-- Name: note_tag note_tag_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.note_tag
    ADD CONSTRAINT note_tag_pkey PRIMARY KEY (id);


--
-- Name: organization organization_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.organization
    ADD CONSTRAINT organization_pkey PRIMARY KEY (id);


--
-- Name: priority_contact priority_contact_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.priority_contact
    ADD CONSTRAINT priority_contact_pkey PRIMARY KEY (id);


--
-- Name: priority_contact priority_contact_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.priority_contact
    ADD CONSTRAINT priority_contact_unique UNIQUE (priority_id, contact_id);


--
-- Name: priority priority_path_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.priority
    ADD CONSTRAINT priority_path_key UNIQUE (path);


--
-- Name: priority priority_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.priority
    ADD CONSTRAINT priority_pkey PRIMARY KEY (id);


--
-- Name: priority_settings priority_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.priority_settings
    ADD CONSTRAINT priority_settings_pkey PRIMARY KEY (user_id, priority_id);


--
-- Name: priority_twist priority_twist_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.priority_twist
    ADD CONSTRAINT priority_twist_pkey PRIMARY KEY (id);


--
-- Name: priority_twist_sync priority_twist_sync_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.priority_twist_sync
    ADD CONSTRAINT priority_twist_sync_pkey PRIMARY KEY (priority_twist_id, entity, operation);


--
-- Name: priority_user priority_user_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.priority_user
    ADD CONSTRAINT priority_user_pkey PRIMARY KEY (user_id, priority_id);


--
-- Name: publisher publisher_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.publisher
    ADD CONSTRAINT publisher_pkey PRIMARY KEY (id);


--
-- Name: series series_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.series
    ADD CONSTRAINT series_pkey PRIMARY KEY (id);


--
-- Name: series series_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.series
    ADD CONSTRAINT series_unique UNIQUE (user_id, series);


--
-- Name: session session_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.session
    ADD CONSTRAINT session_pkey PRIMARY KEY (id);


--
-- Name: token token_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.token
    ADD CONSTRAINT token_pkey PRIMARY KEY (id);


--
-- Name: token token_token_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.token
    ADD CONSTRAINT token_token_key UNIQUE (token);


--
-- Name: twist_admin twist_admin_package_user_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.twist_admin
    ADD CONSTRAINT twist_admin_package_user_unique UNIQUE NULLS NOT DISTINCT (twist_package_id, user_id);


--
-- Name: twist_admin twist_admin_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.twist_admin
    ADD CONSTRAINT twist_admin_pkey PRIMARY KEY (id);


--
-- Name: twist twist_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.twist
    ADD CONSTRAINT twist_pkey PRIMARY KEY (id);


--
-- Name: usage usage_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.usage
    ADD CONSTRAINT usage_pkey PRIMARY KEY (id);


--
-- Name: usage usage_priority_twist_id_hour_cost_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.usage
    ADD CONSTRAINT usage_priority_twist_id_hour_cost_id_key UNIQUE (priority_twist_id, hour, cost_id);


--
-- Name: user user_clerk_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."user"
    ADD CONSTRAINT user_clerk_id_key UNIQUE (clerk_id);


--
-- Name: user user_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."user"
    ADD CONSTRAINT user_pkey PRIMARY KEY (id);


--
-- Name: user_settings user_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_settings
    ADD CONSTRAINT user_settings_pkey PRIMARY KEY (user_id);


--
-- Name: user_subscription user_subscription_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_subscription
    ADD CONSTRAINT user_subscription_pkey PRIMARY KEY (id);


--
-- Name: user_subscription user_subscription_stripe_customer_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_subscription
    ADD CONSTRAINT user_subscription_stripe_customer_id_key UNIQUE (stripe_customer_id);


--
-- Name: user_subscription user_subscription_stripe_subscription_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_subscription
    ADD CONSTRAINT user_subscription_stripe_subscription_id_key UNIQUE (stripe_subscription_id);


--
-- Name: user_subscription user_subscription_user_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_subscription
    ADD CONSTRAINT user_subscription_user_id_key UNIQUE (user_id);


--
-- Name: user_sync user_sync_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_sync
    ADD CONSTRAINT user_sync_pkey PRIMARY KEY (user_id, entity);


--
-- Name: user users_email_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."user"
    ADD CONSTRAINT users_email_unique UNIQUE (email);


--
-- Name: activity_embedding_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX activity_embedding_idx ON public.activity USING hnsw (embedding public.halfvec_cosine_ops);


--
-- Name: activity_exception_occurrence_unique; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX activity_exception_occurrence_unique ON public.activity_exception USING btree (activity_id, occurrence);


--
-- Name: activity_source_priority_unique; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX activity_source_priority_unique ON public.activity USING btree (source, source_priority_root);


--
-- Name: contact_user_primary_unique; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX contact_user_primary_unique ON public.contact USING btree (user_id) WHERE ("primary" = true);


--
-- Name: idx_activity_archived; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_activity_archived ON public.activity USING btree (archived_at) WHERE (archived_at IS NULL);


--
-- Name: idx_activity_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_activity_at ON public.activity USING gist (at);


--
-- Name: idx_activity_created_at_priority; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_activity_created_at_priority ON public.activity USING btree (created_at DESC, priority_id) WHERE (archived_at IS NULL);


--
-- Name: idx_activity_done_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_activity_done_at ON public.activity USING btree (done_at);


--
-- Name: idx_activity_on; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_activity_on ON public.activity USING gist ("on");


--
-- Name: idx_activity_priority_archived; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_activity_priority_archived ON public.activity USING btree (priority_id, archived_at);


--
-- Name: idx_activity_priority_archived_last_note; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_activity_priority_archived_last_note ON public.activity USING btree (priority_id, last_note_created_at, created_at) WHERE (archived_at IS NULL);


--
-- Name: idx_activity_priority_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_activity_priority_id ON public.activity USING btree (priority_id);


--
-- Name: idx_activity_read_activity_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_activity_read_activity_id ON public.activity_read USING btree (activity_id);


--
-- Name: idx_activity_read_user_read; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_activity_read_user_read ON public.activity_read USING btree (user_id, activity_id, read_at);


--
-- Name: idx_activity_source; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_activity_source ON public.activity USING btree (source) WHERE (source IS NOT NULL);


--
-- Name: idx_activity_tag_activity_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_activity_tag_activity_id ON public.activity_tag USING btree (activity_id, tag_id) WHERE (archived_at IS NULL);


--
-- Name: idx_activity_updated_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_activity_updated_at ON public.activity USING btree (updated_at);


--
-- Name: idx_cea_contact; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_cea_contact ON public.contact_external_account USING btree (contact_id);


--
-- Name: idx_cea_reporting; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_cea_reporting ON public.contact_external_account USING btree (provider, last_reported_at);


--
-- Name: idx_contact_invitation_token_redeemed; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_contact_invitation_token_redeemed ON public.contact_invitation USING btree (token, redeemed_at);


--
-- Name: idx_note_activity_archived; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_note_activity_archived ON public.note USING btree (activity_id, archived_at);


--
-- Name: idx_note_activity_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_note_activity_id ON public.note USING btree (activity_id);


--
-- Name: idx_note_author_activity; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_note_author_activity ON public.note USING btree (activity_id, author_id, created_at) WHERE (archived_at IS NULL);


--
-- Name: idx_note_created_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_note_created_at ON public.note USING btree (activity_id, created_at);


--
-- Name: idx_note_key; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_note_key ON public.note USING btree (key) WHERE (key IS NOT NULL);


--
-- Name: idx_note_mentions; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_note_mentions ON public.note USING gin (mentions) WHERE ((mentions IS NOT NULL) AND (archived_at IS NULL));


--
-- Name: idx_note_re_note_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_note_re_note_id ON public.note USING btree (re_note_id) WHERE (re_note_id IS NOT NULL);


--
-- Name: idx_note_tag_note_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_note_tag_note_id ON public.note_tag USING btree (note_id, tag_id) WHERE (archived_at IS NULL);


--
-- Name: idx_note_tag_note_id_full; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_note_tag_note_id_full ON public.note_tag USING btree (note_id);


--
-- Name: idx_note_updated_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_note_updated_at ON public.note USING btree (updated_at);


--
-- Name: idx_priority_key_per_root; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX idx_priority_key_per_root ON public.priority USING btree (public.subltree(path, 0, 1), key) WHERE (key IS NOT NULL);


--
-- Name: idx_priority_path_gist; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_priority_path_gist ON public.priority USING gist (path);


--
-- Name: idx_priority_twist_sync_pending; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_priority_twist_sync_pending ON public.priority_twist_sync USING btree (priority_twist_id) WHERE (last_update_at > last_sync_at);


--
-- Name: idx_priority_twist_twist; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_priority_twist_twist ON public.priority_twist USING btree (twist_id);


--
-- Name: idx_priority_user_personal_priority; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX idx_priority_user_personal_priority ON public.priority_user USING btree (priority_id, personal) WHERE (personal = true);


--
-- Name: idx_priority_user_personal_user; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX idx_priority_user_personal_user ON public.priority_user USING btree (user_id, personal) WHERE (personal = true);


--
-- Name: idx_priority_user_priority_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_priority_user_priority_id ON public.priority_user USING btree (priority_id);


--
-- Name: idx_priority_user_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_priority_user_user_id ON public.priority_user USING btree (user_id) WHERE (archived_at IS NULL);


--
-- Name: idx_priority_user_user_priority_archived; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_priority_user_user_priority_archived ON public.priority_user USING btree (user_id, priority_id, created_at) WHERE (archived_at IS NULL);


--
-- Name: idx_session_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_session_user_id ON public.session USING btree (user_id) WHERE (archived_at IS NULL);


--
-- Name: idx_token_publisher_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_token_publisher_id ON public.token USING btree (publisher_id) WHERE (archived_at IS NULL);


--
-- Name: idx_token_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_token_user_id ON public.token USING btree (user_id) WHERE (archived_at IS NULL);


--
-- Name: idx_twist_admin_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_twist_admin_id ON public.twist USING btree (twist_admin_id);


--
-- Name: idx_twist_admin_priority_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_twist_admin_priority_id ON public.twist_admin USING btree (priority_id);


--
-- Name: idx_twist_admin_publisher_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_twist_admin_publisher_id ON public.twist_admin USING btree (publisher_id);


--
-- Name: idx_twist_admin_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_twist_admin_user_id ON public.twist_admin USING btree (user_id);


--
-- Name: idx_twist_environment; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_twist_environment ON public.twist USING btree (environment);


--
-- Name: idx_twist_priority_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_twist_priority_id ON public.priority_twist USING btree (priority_id);


--
-- Name: idx_usage_priority_twist_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_usage_priority_twist_id ON public.usage USING btree (priority_twist_id);


--
-- Name: idx_user_settings_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_user_settings_user_id ON public.user_settings USING btree (user_id);


--
-- Name: idx_user_subscription_stripe_customer_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_user_subscription_stripe_customer_id ON public.user_subscription USING btree (stripe_customer_id);


--
-- Name: idx_user_subscription_stripe_subscription_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_user_subscription_stripe_subscription_id ON public.user_subscription USING btree (stripe_subscription_id) WHERE (stripe_subscription_id IS NOT NULL);


--
-- Name: idx_user_subscription_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_user_subscription_user_id ON public.user_subscription USING btree (user_id);


--
-- Name: idx_user_sync_pending; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_user_sync_pending ON public.user_sync USING btree (user_id) WHERE (last_update_at > last_sync_at);


--
-- Name: name; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX name ON public.domain USING btree (name);


--
-- Name: note_activity_key_unique; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX note_activity_key_unique ON public.note USING btree (activity_id, key);


--
-- Name: session_at_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX session_at_idx ON public.session USING spgist (at);


--
-- Name: twist_admin_environment_unique; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX twist_admin_environment_unique ON public.twist USING btree (twist_admin_id, environment);


--
-- Name: activity_exception activity_exception_activity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.activity_exception
    ADD CONSTRAINT activity_exception_activity_id_fkey FOREIGN KEY (activity_id) REFERENCES public.activity(id) ON DELETE CASCADE;


--
-- Name: activity activity_priority_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.activity
    ADD CONSTRAINT activity_priority_id_fkey FOREIGN KEY (priority_id) REFERENCES public.priority(id) ON DELETE CASCADE;


--
-- Name: activity_read activity_read_activity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.activity_read
    ADD CONSTRAINT activity_read_activity_id_fkey FOREIGN KEY (activity_id) REFERENCES public.activity(id) ON DELETE CASCADE;


--
-- Name: activity_read activity_read_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.activity_read
    ADD CONSTRAINT activity_read_user_id_fkey FOREIGN KEY (user_id) REFERENCES public."user"(id) ON DELETE CASCADE;


--
-- Name: activity_tag activity_tag_activity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.activity_tag
    ADD CONSTRAINT activity_tag_activity_id_fkey FOREIGN KEY (activity_id) REFERENCES public.activity(id) ON DELETE CASCADE;


--
-- Name: contact_external_account contact_external_account_contact_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.contact_external_account
    ADD CONSTRAINT contact_external_account_contact_id_fkey FOREIGN KEY (contact_id) REFERENCES public.contact(id) ON DELETE CASCADE;


--
-- Name: contact_invitation contact_invitation_contact_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.contact_invitation
    ADD CONSTRAINT contact_invitation_contact_id_fkey FOREIGN KEY (contact_id) REFERENCES public.contact(id) ON DELETE CASCADE;


--
-- Name: contact_invitation contact_invitation_redeemed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.contact_invitation
    ADD CONSTRAINT contact_invitation_redeemed_by_fkey FOREIGN KEY (redeemed_by) REFERENCES public."user"(id) ON DELETE SET NULL;


--
-- Name: contact contact_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.contact
    ADD CONSTRAINT contact_user_id_fkey FOREIGN KEY (user_id) REFERENCES public."user"(id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED;


--
-- Name: domain domain_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.domain
    ADD CONSTRAINT domain_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organization(id) ON DELETE SET NULL;


--
-- Name: note note_activity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.note
    ADD CONSTRAINT note_activity_id_fkey FOREIGN KEY (activity_id) REFERENCES public.activity(id) ON DELETE CASCADE;


--
-- Name: note note_re_note_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.note
    ADD CONSTRAINT note_re_note_id_fkey FOREIGN KEY (re_note_id) REFERENCES public.note(id) ON DELETE SET NULL;


--
-- Name: note_tag note_tag_note_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.note_tag
    ADD CONSTRAINT note_tag_note_id_fkey FOREIGN KEY (note_id) REFERENCES public.note(id) ON DELETE CASCADE;


--
-- Name: priority_contact priority_contact_contact_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.priority_contact
    ADD CONSTRAINT priority_contact_contact_id_fkey FOREIGN KEY (contact_id) REFERENCES public.contact(id) ON DELETE CASCADE;


--
-- Name: priority_contact priority_contact_invited_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.priority_contact
    ADD CONSTRAINT priority_contact_invited_by_fkey FOREIGN KEY (invited_by) REFERENCES public."user"(id) ON DELETE SET NULL;


--
-- Name: priority_contact priority_contact_priority_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.priority_contact
    ADD CONSTRAINT priority_contact_priority_id_fkey FOREIGN KEY (priority_id) REFERENCES public.priority(id) ON DELETE CASCADE;


--
-- Name: priority priority_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.priority
    ADD CONSTRAINT priority_created_by_fkey FOREIGN KEY (created_by) REFERENCES public."user"(id) ON DELETE CASCADE;


--
-- Name: priority_settings priority_settings_priority_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.priority_settings
    ADD CONSTRAINT priority_settings_priority_id_fkey FOREIGN KEY (priority_id) REFERENCES public.priority(id) ON DELETE CASCADE;


--
-- Name: priority_settings priority_settings_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.priority_settings
    ADD CONSTRAINT priority_settings_user_id_fkey FOREIGN KEY (user_id) REFERENCES public."user"(id) ON DELETE CASCADE;


--
-- Name: priority_twist priority_twist_owner_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.priority_twist
    ADD CONSTRAINT priority_twist_owner_id_fkey FOREIGN KEY (owner_id) REFERENCES public."user"(id) ON DELETE CASCADE;


--
-- Name: priority_twist priority_twist_priority_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.priority_twist
    ADD CONSTRAINT priority_twist_priority_id_fkey FOREIGN KEY (priority_id) REFERENCES public.priority(id) ON DELETE CASCADE;


--
-- Name: priority_twist_sync priority_twist_sync_priority_twist_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.priority_twist_sync
    ADD CONSTRAINT priority_twist_sync_priority_twist_id_fkey FOREIGN KEY (priority_twist_id) REFERENCES public.priority_twist(id) ON DELETE CASCADE;


--
-- Name: priority_twist priority_twist_twist_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.priority_twist
    ADD CONSTRAINT priority_twist_twist_id_fkey FOREIGN KEY (twist_id) REFERENCES public.twist(id) ON DELETE CASCADE;


--
-- Name: priority_user priority_user_priority_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.priority_user
    ADD CONSTRAINT priority_user_priority_id_fkey FOREIGN KEY (priority_id) REFERENCES public.priority(id) ON DELETE CASCADE;


--
-- Name: priority_user priority_user_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.priority_user
    ADD CONSTRAINT priority_user_user_id_fkey FOREIGN KEY (user_id) REFERENCES public."user"(id) ON DELETE CASCADE;


--
-- Name: series series_priority_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.series
    ADD CONSTRAINT series_priority_id_fkey FOREIGN KEY (priority_id) REFERENCES public.priority(id) ON DELETE SET NULL;


--
-- Name: series series_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.series
    ADD CONSTRAINT series_user_id_fkey FOREIGN KEY (user_id) REFERENCES public."user"(id) ON DELETE CASCADE;


--
-- Name: session session_priority_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.session
    ADD CONSTRAINT session_priority_id_fkey FOREIGN KEY (priority_id) REFERENCES public.priority(id) ON DELETE SET NULL;


--
-- Name: session session_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.session
    ADD CONSTRAINT session_user_id_fkey FOREIGN KEY (user_id) REFERENCES public."user"(id) ON DELETE CASCADE;


--
-- Name: token token_publisher_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.token
    ADD CONSTRAINT token_publisher_id_fkey FOREIGN KEY (publisher_id) REFERENCES public.publisher(id) ON DELETE CASCADE;


--
-- Name: token token_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.token
    ADD CONSTRAINT token_user_id_fkey FOREIGN KEY (user_id) REFERENCES public."user"(id) ON DELETE CASCADE;


--
-- Name: twist_admin twist_admin_priority_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.twist_admin
    ADD CONSTRAINT twist_admin_priority_id_fkey FOREIGN KEY (priority_id) REFERENCES public.priority(id) ON DELETE CASCADE;


--
-- Name: twist_admin twist_admin_publisher_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.twist_admin
    ADD CONSTRAINT twist_admin_publisher_id_fkey FOREIGN KEY (publisher_id) REFERENCES public.publisher(id) ON DELETE CASCADE;


--
-- Name: twist_admin twist_admin_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.twist_admin
    ADD CONSTRAINT twist_admin_user_id_fkey FOREIGN KEY (user_id) REFERENCES public."user"(id) ON DELETE CASCADE;


--
-- Name: twist twist_twist_admin_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.twist
    ADD CONSTRAINT twist_twist_admin_id_fkey FOREIGN KEY (twist_admin_id) REFERENCES public.twist_admin(id) ON DELETE CASCADE;


--
-- Name: usage usage_cost_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.usage
    ADD CONSTRAINT usage_cost_id_fkey FOREIGN KEY (cost_id) REFERENCES public.cost(id) ON DELETE CASCADE;


--
-- Name: usage usage_priority_twist_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.usage
    ADD CONSTRAINT usage_priority_twist_id_fkey FOREIGN KEY (priority_twist_id) REFERENCES public.priority_twist(id) ON DELETE CASCADE;


--
-- Name: user_settings user_settings_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_settings
    ADD CONSTRAINT user_settings_user_id_fkey FOREIGN KEY (user_id) REFERENCES public."user"(id) ON DELETE CASCADE;


--
-- Name: user_subscription user_subscription_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_subscription
    ADD CONSTRAINT user_subscription_user_id_fkey FOREIGN KEY (user_id) REFERENCES public."user"(id) ON DELETE CASCADE;


--
-- Name: user_sync user_sync_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_sync
    ADD CONSTRAINT user_sync_user_id_fkey FOREIGN KEY (user_id) REFERENCES public."user"(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--


