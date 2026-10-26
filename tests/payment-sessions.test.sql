-- Real PostgreSQL tests for the new prepared ledger, never external charges.
\set ON_ERROR_STOP on
\i supabase/changes/05_payment_sessions_PREPARED.sql
CREATE TEMP TABLE unlock_effects(order_id uuid);
CREATE FUNCTION private.test_unlock_effect() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN INSERT INTO pg_temp.unlock_effects VALUES(NEW.id); RETURN NEW; END;
$$;
CREATE TRIGGER test_unlock_effect AFTER UPDATE OF contact_unlocked ON public.orders
FOR EACH ROW EXECUTE FUNCTION private.test_unlock_effect();
INSERT INTO public.orders(id,payload,shop_id,seller_id,phone_verified)
VALUES('12121212-1212-4212-8212-121212121212','{}','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
 '11111111-1111-4111-8111-111111111111',true),
 ('13131313-1313-4313-8313-131313131313','{}','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
 '11111111-1111-4111-8111-111111111111',false);
DO $test$
DECLARE p jsonb; e jsonb; r jsonb;
BEGIN
  p:=public.prepare_contact_payment('12121212-1212-4212-8212-121212121212',
    '11111111-1111-4111-8111-111111111111','FAKE_TEST_ONLY','m1');
  IF p IS DISTINCT FROM public.prepare_contact_payment('12121212-1212-4212-8212-121212121212',
    '11111111-1111-4111-8111-111111111111','FAKE_TEST_ONLY','m1') THEN
    RAISE EXCEPTION 'payment_retry_not_identical';
  END IF;
  BEGIN
    PERFORM public.prepare_contact_payment('12121212-1212-4212-8212-121212121212',
      '22222222-2222-4222-8222-222222222222','FAKE_TEST_ONLY','m1');
    RAISE EXCEPTION 'wrong_seller_allowed';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM<>'order_not_found' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public.prepare_contact_payment('13131313-1313-4313-8313-131313131313',
      '11111111-1111-4111-8111-111111111111','FAKE_TEST_ONLY','m1');
    RAISE EXCEPTION 'unverified_allowed';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM<>'otp_not_verified' THEN RAISE; END IF;
  END;
  PERFORM public.save_contact_payment_session((p->>'id')::uuid,'ps1','https://sandbox.example/pay');
  e:=jsonb_build_object('provider','FAKE_TEST_ONLY','merchant_id','m1','event_id','event-1',
    'transaction_id','transaction-1','payment_id',p->>'id','order_id',p->>'order_id',
    'session_id','ps1','amount_minor',500,'currency','MAD','status','succeeded');
  BEGIN
    PERFORM public.apply_contact_payment_event(e||'{"amount_minor":499}');
    RAISE EXCEPTION 'bad_amount_allowed';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'invalid_payment_event' THEN RAISE; END IF; END;
  BEGIN
    PERFORM public.apply_contact_payment_event(e||'{"order_id":"13131313-1313-4313-8313-131313131313"}');
    RAISE EXCEPTION 'wrong_order_allowed';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'payment_identity_mismatch' THEN RAISE; END IF; END;
  PERFORM public.apply_contact_payment_event(e);
  r:=public.apply_contact_payment_event(e);
  IF r->>'duplicate_event'<>'true' THEN RAISE EXCEPTION 'event_not_deduplicated'; END IF;
  IF NOT (SELECT contact_unlocked FROM public.orders WHERE id=(p->>'order_id')::uuid) THEN
    RAISE EXCEPTION 'confirmed_payment_not_unlocked';
  END IF;
  PERFORM public.apply_contact_payment_event(e||'{"event_id":"same-transaction-new-event"}');
  IF (SELECT count(*) FROM pg_temp.unlock_effects WHERE order_id=(p->>'order_id')::uuid)<>1 THEN
    RAISE EXCEPTION 'duplicate_success_retriggered_unlock_side_effects';
  END IF;
  BEGIN
    PERFORM public.apply_contact_payment_event(e||'{"currency":"EUR"}');
    RAISE EXCEPTION 'changed_replay_allowed';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'invalid_payment_event' THEN RAISE; END IF; END;
  BEGIN
    PERFORM public.apply_contact_payment_event(e||'{"event_id":"event-2","transaction_id":"second-charge"}');
    RAISE EXCEPTION 'second_charge_allowed';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'additional_charge_requires_reconciliation' THEN RAISE; END IF; END;
  BEGIN
    PERFORM public.apply_contact_payment_event(e||'{"event_id":"event-2","status":"failed"}');
    RAISE EXCEPTION 'late_failure_overwrote_success';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'stale_payment_event' THEN RAISE; END IF; END;
  PERFORM public.apply_contact_payment_event(e||'{"event_id":"refund-1","status":"refunded"}');
  IF (SELECT contact_unlocked FROM public.orders WHERE id=(p->>'order_id')::uuid) THEN
    RAISE EXCEPTION 'refund_not_relocked';
  END IF;
  BEGIN
    PERFORM public.apply_contact_payment_event(e||'{"event_id":"late-success"}');
    RAISE EXCEPTION 'late_success_reopened_refunded';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'terminal_payment_requires_reconciliation' THEN RAISE; END IF; END;
END
$test$;
SET ROLE authenticated;
DO $test$
BEGIN
  BEGIN
    PERFORM public.prepare_contact_payment('12121212-1212-4212-8212-121212121212',
      '11111111-1111-4111-8111-111111111111','FAKE_TEST_ONLY','m1');
    RAISE EXCEPTION 'browser_can_impersonate_seller';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN
    PERFORM public.apply_contact_payment_event('{}');
    RAISE EXCEPTION 'browser_can_finalize';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END
$test$;
RESET ROLE;
\echo PASS payment ledger: fixed amount, stable ID, seller/OTP checks, replay, refund, stale events, service-only ACL.

-- Failed/cancelled sessions cannot unlock or be silently replaced after timeout.
DO $test$
DECLARE o uuid; p jsonb; e jsonb; v_status text;
BEGIN
  FOREACH v_status IN ARRAY ARRAY['failed','cancelled'] LOOP
    o:=gen_random_uuid();
    INSERT INTO public.orders(id,payload,shop_id,seller_id,phone_verified)
    VALUES(o,'{}','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','11111111-1111-4111-8111-111111111111',true);
    p:=public.prepare_contact_payment(o,'11111111-1111-4111-8111-111111111111','FAKE_TEST_ONLY','m1');
    PERFORM public.save_contact_payment_session((p->>'id')::uuid,o::text,'https://sandbox.example/pay');
    e:=jsonb_build_object('provider','FAKE_TEST_ONLY','merchant_id','m1','event_id',o::text,
      'transaction_id',o::text,'payment_id',p->>'id','order_id',o,'session_id',o::text,
      'amount_minor',500,'currency','MAD','status',v_status);
    PERFORM public.apply_contact_payment_event(e);
    IF (SELECT contact_unlocked FROM public.orders WHERE id=o) THEN RAISE EXCEPTION 'failed_payment_unlocked'; END IF;
    IF (public.prepare_contact_payment(o,'11111111-1111-4111-8111-111111111111','FAKE_TEST_ONLY','m1')->>'id')
      IS DISTINCT FROM p->>'id' THEN RAISE EXCEPTION 'terminal_payment_replaced'; END IF;
    BEGIN
      PERFORM public.apply_contact_payment_event(e||jsonb_build_object('event_id',o::text||'-changed','status','succeeded'));
      RAISE EXCEPTION 'cancelled_attempt_captured_without_reconciliation';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM<>'terminal_payment_requires_reconciliation' THEN RAISE; END IF;
    END;
  END LOOP;
END
$test$;

-- Neither a reused PSP transaction nor a reused event identity can cross orders.
DO $test$
DECLARE o uuid:=gen_random_uuid(); p jsonb; e jsonb;
BEGIN
  INSERT INTO public.orders(id,payload,shop_id,seller_id,phone_verified)
  VALUES(o,'{}','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','11111111-1111-4111-8111-111111111111',true);
  p:=public.prepare_contact_payment(o,'11111111-1111-4111-8111-111111111111','FAKE_TEST_ONLY','m1');
  PERFORM public.save_contact_payment_session((p->>'id')::uuid,'cross-session','https://sandbox.example/pay');
  e:=jsonb_build_object('provider','FAKE_TEST_ONLY','merchant_id','m1','event_id','cross-event',
    'transaction_id','transaction-1','payment_id',p->>'id','order_id',o,'session_id','cross-session',
    'amount_minor',500,'currency','MAD','status','succeeded');
  BEGIN
    PERFORM public.apply_contact_payment_event(e);
    RAISE EXCEPTION 'transaction_reused_across_orders';
  EXCEPTION WHEN unique_violation THEN NULL; END;
  IF (SELECT contact_unlocked FROM public.orders WHERE id=o) THEN RAISE EXCEPTION 'unique_failure_not_atomic'; END IF;
  BEGIN
    PERFORM public.apply_contact_payment_event(e||'{"event_id":"event-1","transaction_id":"different-transaction"}');
    RAISE EXCEPTION 'event_reused_across_orders';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'event_replay_conflict' THEN RAISE; END IF; END;
  IF (SELECT contact_unlocked FROM public.orders WHERE id=o) THEN RAISE EXCEPTION 'replay_failure_not_atomic'; END IF;
END
$test$;
\echo PASS terminal payments, cross-order PSP transaction/event uniqueness and atomic rejection.

DROP TRIGGER test_unlock_effect ON public.orders;
DROP FUNCTION private.test_unlock_effect();
