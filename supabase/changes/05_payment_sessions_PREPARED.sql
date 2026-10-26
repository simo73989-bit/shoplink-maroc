-- PREPARED ONLY. No provider is enabled by this migration.
-- Requires isolated real-schema integration, backup, 04 and legacy billing cutover.
-- This ledger is intentionally separate from the undocumented legacy payment table.
-- Never run both legacy and new finalizers for the same order.
BEGIN;
CREATE TABLE private.contact_payment_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL UNIQUE REFERENCES public.orders(id),
  provider text NOT NULL,
  merchant_id text NOT NULL,
  amount_minor integer NOT NULL DEFAULT 500 CHECK(amount_minor=500),
  currency text NOT NULL DEFAULT 'MAD' CHECK(currency='MAD'),
  status text NOT NULL DEFAULT 'pending'
    CHECK(status IN ('pending','succeeded','failed','cancelled','refunded')),
  provider_session_id text,
  checkout_url text,
  provider_transaction_id text,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(provider,merchant_id,provider_session_id),
  UNIQUE(provider,merchant_id,provider_transaction_id)
);
CREATE TABLE private.contact_payment_events (
  provider text NOT NULL,
  merchant_id text NOT NULL,
  event_id text NOT NULL,
  payload jsonb NOT NULL,
  PRIMARY KEY(provider,merchant_id,event_id)
);
ALTER TABLE private.contact_payment_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.contact_payment_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.contact_payment_sessions,private.contact_payment_events
  FROM PUBLIC,anon,authenticated;

-- Edge service first validates the seller JWT with Auth, then passes that user ID.
-- This RPC must NEVER be granted to authenticated/anon: caller identity is an argument.
CREATE FUNCTION public.prepare_contact_payment(p_order_id uuid,p_seller_id uuid,
  p_provider text,p_merchant_id text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $fn$
DECLARE o public.orders%ROWTYPE; p private.contact_payment_sessions%ROWTYPE;
BEGIN
  IF nullif(p_provider,'') IS NULL OR nullif(p_merchant_id,'') IS NULL THEN
    RAISE EXCEPTION 'provider_not_configured';
  END IF;
  SELECT * INTO o FROM public.orders WHERE id=p_order_id FOR UPDATE;
  IF NOT FOUND OR p_seller_id IS NULL OR o.seller_id IS DISTINCT FROM p_seller_id
    OR NOT EXISTS(SELECT 1 FROM public.shops WHERE id=o.shop_id AND owner_id=p_seller_id) THEN
    RAISE EXCEPTION 'order_not_found';
  END IF;
  IF o.phone_verified IS NOT TRUE THEN RAISE EXCEPTION 'otp_not_verified'; END IF;
  IF o.contact_unlocked IS TRUE THEN RETURN jsonb_build_object('unlocked',true); END IF;
  SELECT * INTO p FROM private.contact_payment_sessions WHERE order_id=o.id;
  IF NOT FOUND THEN
    INSERT INTO private.contact_payment_sessions(order_id,provider,merchant_id)
    VALUES(o.id,p_provider,p_merchant_id) RETURNING * INTO p;
  END IF;
  IF p.provider<>p_provider OR p.merchant_id<>p_merchant_id THEN
    RAISE EXCEPTION 'provider_change_requires_reconciliation';
  END IF;
  RETURN to_jsonb(p); -- service-role only; contains no customer contact
END;
$fn$;

CREATE FUNCTION public.save_contact_payment_session(p_payment_id uuid,
  p_session_id text,p_checkout_url text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $fn$
DECLARE p private.contact_payment_sessions%ROWTYPE;
BEGIN
  IF nullif(p_session_id,'') IS NULL OR p_checkout_url IS NULL OR p_checkout_url !~ '^https://' THEN
    RAISE EXCEPTION 'invalid_provider_session';
  END IF;
  SELECT * INTO p FROM private.contact_payment_sessions WHERE id=p_payment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'payment_not_found'; END IF;
  IF p.status<>'pending' THEN RAISE EXCEPTION 'payment_terminal'; END IF;
  IF p.provider_session_id IS NOT NULL AND
     (p.provider_session_id<>p_session_id OR p.checkout_url<>p_checkout_url) THEN
    RAISE EXCEPTION 'provider_idempotency_violation';
  END IF;
  UPDATE private.contact_payment_sessions SET provider_session_id=p_session_id,
    checkout_url=p_checkout_url WHERE id=p.id RETURNING * INTO p;
  RETURN to_jsonb(p);
END;
$fn$;

-- Only an adapter-authenticated event reconciled against the official PSP status API
-- may reach this service RPC. Do not expose it to browser roles or legacy callbacks.
CREATE FUNCTION public.apply_contact_payment_event(p_event jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $fn$
DECLARE p private.contact_payment_sessions%ROWTYPE; o public.orders%ROWTYPE;
  prior jsonb; v_status text := p_event->>'status'; v_order uuid;
BEGIN
  IF jsonb_typeof(p_event)<>'object' OR p_event IS NULL
    OR nullif(p_event->>'provider','') IS NULL OR nullif(p_event->>'merchant_id','') IS NULL
    OR nullif(p_event->>'event_id','') IS NULL OR nullif(p_event->>'transaction_id','') IS NULL
    OR nullif(p_event->>'session_id','') IS NULL
    OR p_event->>'currency' IS DISTINCT FROM 'MAD'
    OR p_event->'amount_minor' IS DISTINCT FROM '500'::jsonb
    OR v_status IS NULL OR v_status NOT IN ('succeeded','failed','cancelled','refunded') THEN
    RAISE EXCEPTION 'invalid_payment_event';
  END IF;
  SELECT order_id INTO v_order FROM private.contact_payment_sessions WHERE id=(p_event->>'payment_id')::uuid;
  IF v_order IS NULL THEN RAISE EXCEPTION 'payment_not_found'; END IF;
  -- Consistent lock order with prepare: order first, payment second.
  SELECT * INTO o FROM public.orders WHERE id=v_order FOR UPDATE;
  SELECT * INTO p FROM private.contact_payment_sessions WHERE id=(p_event->>'payment_id')::uuid FOR UPDATE;
  IF p.order_id IS DISTINCT FROM (p_event->>'order_id')::uuid
    OR p.provider IS DISTINCT FROM p_event->>'provider'
    OR p.merchant_id IS DISTINCT FROM p_event->>'merchant_id'
    OR p.provider_session_id IS DISTINCT FROM p_event->>'session_id' THEN
    RAISE EXCEPTION 'payment_identity_mismatch';
  END IF;
  -- Unique event key serializes even events naming two different payments.
  INSERT INTO private.contact_payment_events(provider,merchant_id,event_id,payload)
  VALUES(p.provider,p.merchant_id,p_event->>'event_id',p_event)
  ON CONFLICT DO NOTHING;
  IF NOT FOUND THEN
    SELECT payload INTO prior FROM private.contact_payment_events
    WHERE provider=p.provider AND merchant_id=p.merchant_id AND event_id=p_event->>'event_id';
    IF prior IS DISTINCT FROM p_event THEN RAISE EXCEPTION 'event_replay_conflict'; END IF;
    RETURN jsonb_build_object('duplicate_event',true);
  END IF;
  IF p.provider_transaction_id IS NOT NULL AND
    p.provider_transaction_id<>p_event->>'transaction_id' THEN
    RAISE EXCEPTION 'additional_charge_requires_reconciliation';
  END IF;
  IF v_status='succeeded' THEN
    IF p.status NOT IN ('pending','succeeded') THEN RAISE EXCEPTION 'terminal_payment_requires_reconciliation'; END IF;
    IF o.phone_verified IS NOT TRUE THEN RAISE EXCEPTION 'otp_not_verified'; END IF;
    IF p.status='pending' THEN
      UPDATE public.orders SET contact_unlocked=true,payment_status='succeeded',
        unlocked_at=coalesce(unlocked_at,now()) WHERE id=o.id;
    END IF;
  ELSIF v_status='refunded' THEN
    IF p.status NOT IN ('succeeded','refunded') THEN RAISE EXCEPTION 'refund_without_capture'; END IF;
    IF p.status='succeeded' THEN
      UPDATE public.orders SET contact_unlocked=false,payment_status='refunded' WHERE id=o.id;
    END IF;
  ELSE
    IF p.status NOT IN ('pending',v_status) THEN RAISE EXCEPTION 'stale_payment_event'; END IF;
    -- Never open contacts on failure/cancellation; late contradictory events require review.
  END IF;
  UPDATE private.contact_payment_sessions SET status=v_status,
    provider_transaction_id=p_event->>'transaction_id' WHERE id=p.id;
  RETURN jsonb_build_object('ok',true,'status',v_status);
END;
$fn$;

REVOKE ALL ON FUNCTION public.prepare_contact_payment(uuid,uuid,text,text),
  public.save_contact_payment_session(uuid,text,text),public.apply_contact_payment_event(jsonb)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.prepare_contact_payment(uuid,uuid,text,text),
  public.save_contact_payment_session(uuid,text,text),public.apply_contact_payment_event(jsonb)
  TO service_role;
COMMIT;
-- Rollback: disable payment endpoints; retain ledger/events. Never re-open old charging.
-- Failed/cancelled/refunded attempts cannot start a new charge automatically. An operator
-- must reconcile PSP state (including old URLs) before any future attempt generation.
