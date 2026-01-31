-- Email delivery helper functions

-- Create email delivery record with idempotency check
CREATE OR REPLACE FUNCTION create_email_delivery(
  p_idempotency_key TEXT,
  p_template TEXT,
  p_to_addresses TEXT[],
  p_subject TEXT,
  p_template_props JSONB DEFAULT NULL,
  p_max_retries INT DEFAULT 10
)
RETURNS TABLE (
  id UUID,
  status TEXT,
  already_sent BOOLEAN
) AS $$
DECLARE
  v_existing_id UUID;
  v_existing_status TEXT;
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
      (v_existing_status = 'sent')::BOOLEAN;
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
  RETURNING email_delivery.id, email_delivery.status, FALSE;
END;
$$ LANGUAGE plpgsql;

-- Mark email as successfully sent
CREATE OR REPLACE FUNCTION mark_email_sent(
  p_idempotency_key TEXT,
  p_resend_id TEXT
)
RETURNS VOID AS $$
BEGIN
  UPDATE email_delivery
  SET
    status = 'sent',
    sent_at = now(),
    resend_id = p_resend_id,
    last_error = NULL
  WHERE idempotency_key = p_idempotency_key;
END;
$$ LANGUAGE plpgsql;

-- Increment retry count and return current state
CREATE OR REPLACE FUNCTION increment_email_retry(
  p_idempotency_key TEXT,
  p_error TEXT
)
RETURNS TABLE (
  retry_count INT,
  max_retries INT,
  should_expire BOOLEAN
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
    (email_delivery.retry_count >= email_delivery.max_retries)::BOOLEAN
  INTO increment_email_retry.retry_count, increment_email_retry.max_retries, increment_email_retry.should_expire;

  RETURN NEXT;
END;
$$ LANGUAGE plpgsql;

-- Mark email as expired (after max retries)
CREATE OR REPLACE FUNCTION mark_email_expired(
  p_idempotency_key TEXT
)
RETURNS VOID AS $$
BEGIN
  UPDATE email_delivery
  SET status = 'expired'
  WHERE idempotency_key = p_idempotency_key;
END;
$$ LANGUAGE plpgsql;
