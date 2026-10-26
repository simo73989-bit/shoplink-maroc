-- PREPARED ONLY. Apply in isolated staging and test before production.
-- Prerequisite: public.place_public_order_v2 exists and retains its secure implementation.
-- Migration 1 must be deployed BEFORE the frontend calls place_public_order_idempotent.
CREATE TABLE IF NOT EXISTS public.order_create_attempts (
  request_id uuid PRIMARY KEY,
  payload_hash text NOT NULL CHECK (char_length(payload_hash) = 64),
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  response jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.order_create_attempts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.order_create_attempts FROM PUBLIC, anon, authenticated;
-- No client RLS policies: this table is only used inside the security-definer function.
CREATE OR REPLACE FUNCTION public.place_public_order_idempotent(
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
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_hash text;
  v_existing public.order_create_attempts%ROWTYPE;
  v_response jsonb;
BEGIN
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'request_id_required'; END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN RAISE EXCEPTION 'invalid_items'; END IF;
  -- Digest only: no full phone or customer address stored in the attempt table.
  v_hash := md5(jsonb_build_array(
    p_shop_id,p_customer_name,p_phone,p_city,p_address,p_delivery_method,p_note,p_items
  )::text);
  -- sha256 expressed as 64 hex digits: use standard pgcrypto digest in extensions.
  v_hash := encode(extensions.digest(v_hash,'sha256'),'hex');
  -- Serialize retries of the same request across devices/sessions.
  PERFORM pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));
  SELECT * INTO v_existing FROM public.order_create_attempts
  WHERE request_id=p_request_id;
  IF FOUND THEN
    IF v_existing.payload_hash <> v_hash THEN RAISE EXCEPTION 'idempotency_conflict'; END IF;
    RETURN v_existing.response;
  END IF;
  v_response := public.place_public_order_v2(
    p_shop_id,p_customer_name,p_phone,p_city,p_address,p_delivery_method,p_note,p_items
  );
  IF v_response IS NULL OR NOT (v_response ? 'id') THEN
    RAISE EXCEPTION 'unexpected_order_result';
  END IF;
  INSERT INTO public.order_create_attempts(request_id,payload_hash,order_id,response)
  VALUES (p_request_id,v_hash,(v_response->>'id')::uuid,v_response);
  RETURN v_response;
END
$fn$;
REVOKE ALL ON FUNCTION public.place_public_order_idempotent(
  uuid,uuid,text,text,text,text,text,text,jsonb
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.place_public_order_idempotent(
  uuid,uuid,text,text,text,text,text,text,jsonb
) TO anon, authenticated, service_role;
-- IMPORTANT: validate with concurrent requests and lost responses in staging.
