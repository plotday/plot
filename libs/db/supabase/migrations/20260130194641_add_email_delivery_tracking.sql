-- Email delivery tracking table
-- Tracks every email sent through the system with full lifecycle and retry state

CREATE TABLE public.email_delivery (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  idempotency_key text NOT NULL UNIQUE,

  -- Email metadata
  template text NOT NULL,
  to_addresses text[] NOT NULL,
  subject text NOT NULL,
  template_props jsonb,

  -- Delivery state
  status text NOT NULL CHECK (status IN ('pending', 'sent', 'failed', 'expired')),
  retry_count integer NOT NULL DEFAULT 0,
  max_retries integer NOT NULL DEFAULT 10,

  -- Timing
  created_at timestamptz NOT NULL DEFAULT now(),
  sent_at timestamptz,
  last_attempt_at timestamptz,

  -- Error tracking
  last_error text,
  resend_id text
);

-- Indexes
CREATE INDEX email_delivery_created_at_idx ON public.email_delivery(created_at);
CREATE INDEX email_delivery_status_idx ON public.email_delivery(status) WHERE status IN ('pending', 'failed');
CREATE INDEX email_delivery_idempotency_key_idx ON public.email_delivery(idempotency_key);

-- Enable RLS
ALTER TABLE public.email_delivery ENABLE ROW LEVEL SECURITY;

-- No direct access - only via service role and SECURITY DEFINER functions
-- (emails contain sensitive data and should only be accessed via API functions)
CREATE POLICY email_delivery_no_access ON public.email_delivery
  FOR ALL
  USING (false);

-- Email delivery helper functions

-- Create email delivery record with idempotency check
CREATE OR REPLACE FUNCTION public.create_email_delivery(
  p_idempotency_key text,
  p_template text,
  p_to_addresses text[],
  p_subject text,
  p_template_props jsonb DEFAULT NULL,
  p_max_retries integer DEFAULT 10
)
RETURNS TABLE (
  id uuid,
  status text,
  already_sent boolean
) AS $$
DECLARE
  v_existing_id uuid;
  v_existing_status text;
BEGIN
  -- Check for existing email
  SELECT ed.id, ed.status INTO v_existing_id, v_existing_status
  FROM email_delivery ed
  WHERE ed.idempotency_key = p_idempotency_key;

  IF v_existing_id IS NOT NULL THEN
    -- Email already exists
    RETURN QUERY SELECT
      v_existing_id,
      v_existing_status,
      (v_existing_status = 'sent')::boolean;
    RETURN;
  END IF;

  -- Create new email
  RETURN QUERY
  INSERT INTO email_delivery (
    idempotency_key,
    template,
    to_addresses,
    subject,
    template_props,
    max_retries,
    status
  ) VALUES (
    p_idempotency_key,
    p_template,
    p_to_addresses,
    p_subject,
    p_template_props,
    p_max_retries,
    'pending'
  )
  RETURNING email_delivery.id, email_delivery.status, false;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Mark email as successfully sent
CREATE OR REPLACE FUNCTION public.mark_email_sent(
  p_idempotency_key text,
  p_resend_id text
)
RETURNS void AS $$
BEGIN
  UPDATE email_delivery
  SET
    status = 'sent',
    sent_at = now(),
    resend_id = p_resend_id,
    last_error = NULL
  WHERE idempotency_key = p_idempotency_key;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Increment retry count and return current state
CREATE OR REPLACE FUNCTION public.increment_email_retry(
  p_idempotency_key text,
  p_error text
)
RETURNS TABLE (
  retry_count integer,
  max_retries integer,
  should_expire boolean
) AS $$
BEGIN
  UPDATE email_delivery
  SET
    retry_count = email_delivery.retry_count + 1,
    last_error = p_error,
    last_attempt_at = now(),
    status = 'failed'
  WHERE idempotency_key = p_idempotency_key
  RETURNING
    email_delivery.retry_count,
    email_delivery.max_retries,
    (email_delivery.retry_count >= email_delivery.max_retries)::boolean
  INTO increment_email_retry.retry_count, increment_email_retry.max_retries, increment_email_retry.should_expire;

  RETURN NEXT;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Mark email as expired (after max retries)
CREATE OR REPLACE FUNCTION public.mark_email_expired(
  p_idempotency_key text
)
RETURNS void AS $$
BEGIN
  UPDATE email_delivery
  SET status = 'expired'
  WHERE idempotency_key = p_idempotency_key;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
