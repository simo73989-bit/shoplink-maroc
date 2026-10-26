-- PREPARED ONLY: requires isolated staging testing and backup before production.
-- Deploy this SQL BEFORE deploying the frontend using place_public_order_idempotent.
-- One transaction ensures incomplete installation rolls back.
BEGIN;

-- Fail safely if this table already exists unexpectedly; inspect and migrate it explicitly.
CREATE TABLE public.order_create_attempts (
  request_id uuid PRIMARY KEY,
  payload_hash text NOT NULL CHECK (length(payload_hash)=64),
  -- Keep tombstones even when sellers physically delete orders.
  order_id uuid REFERENCES public.orders(id) ON DELETE SET NULL,
  response jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.order_create_attempts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.order_create_attempts FROM PUBLIC, anon, authenticated;
-- No direct access policies for anon/authenticated. Only the RPC owner can read/write attempts.

CREATE FUNCTION public.place_public_order_idempotent(
  p_request_id uuid,
  p_shop_id uuid,
  p_customer_name text,
  p_phone text,
  p_city text,
  p_address text,
  p_delivery_method text,
  p_note text,
  p_items jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
  v_hash text;
  v_existing public.order_create_attempts%ROWTYPE;
  v_result jsonb;
  v_public_response jsonb;
BEGIN
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'request_id_required'; END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items)<>'array' THEN RAISE EXCEPTION 'invalid_items'; END IF;

  -- Fingerprint EXACTLY the RPC business arguments; hash the JSON directly.
  -- The attempts table never stores the clear customer contact or full payload.
  v_hash := encode(extensions.digest(
    jsonb_build_array(p_shop_id,p_customer_name,p_phone,p_city,p_address,
                      p_delivery_method,p_note,p_items)::text, 'sha256'
  ), 'hex');

  PERFORM pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));
  SELECT * INTO v_existing
    FROM public.order_create_attempts
   WHERE request_id=p_request_id;

  IF FOUND THEN
    IF v_existing.payload_hash<>v_hash THEN RAISE EXCEPTION 'idempotency_conflict'; END IF;
    IF v_existing.order_id IS NULL THEN RAISE EXCEPTION 'order_deleted'; END IF;
    -- Return the saved result; never create again on a retry.
    RETURN v_existing.response;
  END IF;

  v_result := public.place_public_order_v2(
    p_shop_id,p_customer_name,p_phone,p_city,p_address,
    p_delivery_method,p_note,p_items
  );
  IF v_result IS NULL OR jsonb_typeof(v_result) <> 'object'
     OR nullif(v_result->>'id','') IS NULL
     OR nullif(v_result->>'order_number','') IS NULL THEN
    RAISE EXCEPTION 'unexpected_order_result';
  END IF;

  -- Allowlist only fields needed to resume checkout (not phone/address/note).
  v_public_response := jsonb_build_object(
    'id',v_result->'id',
    'order_number',v_result->'order_number',
    'total',v_result->'total',
    'created_at',v_result->'created_at',
    'phone_verified',v_result->'phone_verified',
    'reused_pending',v_result->'reused_pending',
    'verification_expires_at',v_result->'verification_expires_at'
  );
  INSERT INTO public.order_create_attempts(request_id,payload_hash,order_id,response)
  VALUES (p_request_id,v_hash,(v_result->>'id')::uuid,v_public_response);
  RETURN v_public_response;
END;
$fn$;

REVOKE ALL ON FUNCTION public.place_public_order_idempotent(
  uuid,uuid,text,text,text,text,text,text,jsonb
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.place_public_order_idempotent(
  uuid,uuid,text,text,text,text,text,text,jsonb
) TO anon, authenticated, service_role;

COMMIT;
-- Keep attempt markers beyond maximum client retry window; define a data-retention
-- policy before launch. Never delete tombstones while clients can replay UUIDs.
-- Staging tests: same UUID concurrent/retry, different payload, deleted order/retry,
-- disconnected first response, transaction rollback, RLS, stock, and rate limits.
