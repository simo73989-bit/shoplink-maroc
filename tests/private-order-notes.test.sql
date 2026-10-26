-- Disposable PostgreSQL only; fake buyers, fake phones, fake shop owners.
\set ON_ERROR_STOP on

INSERT INTO public.shops(id,owner_id)
VALUES ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','11111111-1111-4111-8111-111111111111'),
       ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','22222222-2222-4222-8222-222222222222');

-- This order was created before the privacy migration and contains a raw contact in note.
INSERT INTO public.orders(id,payload,shop_id,seller_id,customer_name,phone,city,note,
  phone_verified,verification_expires_at,updated_at)
VALUES ('cccccccc-cccc-4ccc-8ccc-cccccccccccc','{}'::jsonb,
 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','11111111-1111-4111-8111-111111111111',
 'Fake Customer','061*****99','Sale','Call 0600000099',true,now()+interval '1 hour',
 '2023-01-01 12:00:00+00'::timestamptz);
INSERT INTO public.order_contacts(order_id,phone,address)
VALUES ('cccccccc-cccc-4ccc-8ccc-cccccccccccc','0600000099','Test street');

ALTER TABLE public.orders ENABLE ALWAYS TRIGGER orders_updated_at;
CREATE TEMP TABLE historical_before AS SELECT * FROM public.orders;
-- The actual migration is executed in the same isolated database.
\i supabase/changes/04_private_order_notes_PREPARED.sql

DO $test$
DECLARE
  v_note text;
  v_row text;
  v_count integer;
BEGIN
  SELECT count(*) INTO v_count FROM public.orders WHERE note<>'';
  IF v_count<>0 THEN RAISE EXCEPTION 'public_orders_note_leak'; END IF;
  IF (SELECT tgenabled FROM pg_trigger WHERE tgname='orders_updated_at')<>'A' THEN
    RAISE EXCEPTION 'historical_trigger_mode_changed';
  END IF;
  IF EXISTS(SELECT 1 FROM historical_before b FULL JOIN public.orders o USING(id)
    WHERE (to_jsonb(b)-'note') IS DISTINCT FROM (to_jsonb(o)-'note')) THEN
    RAISE EXCEPTION 'migration_changed_historical_order_fields';
  END IF;
  IF (SELECT updated_at FROM public.orders WHERE id='cccccccc-cccc-4ccc-8ccc-cccccccccccc')
     IS DISTINCT FROM '2023-01-01 12:00:00+00'::timestamptz THEN
     RAISE EXCEPTION 'migration_modified_historical_updated_at';
  END IF;

  SELECT note INTO v_note FROM private.order_notes
   WHERE order_id='cccccccc-cccc-4ccc-8ccc-cccccccccccc';
  IF v_note IS DISTINCT FROM 'Call 0600000099' THEN
    RAISE EXCEPTION 'historical_note_not_preserved';
  END IF;

  IF has_schema_privilege('authenticated','private','USAGE') OR
     has_table_privilege('authenticated','private.order_notes','SELECT') THEN
    RAISE EXCEPTION 'private_note_table_publicly_accessible';
  END IF;

  IF NOT (SELECT relrowsecurity FROM pg_class
          WHERE oid='private.order_notes'::regclass) THEN
    RAISE EXCEPTION 'private_note_RLS_missing';
  END IF;

  PERFORM set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',false);
  SELECT phone||'|'||address||'|'||note INTO v_row FROM public.get_seller_orders()
    WHERE id='cccccccc-cccc-4ccc-8ccc-cccccccccccc';
  IF v_row IS DISTINCT FROM '••••••••••||' THEN
    RAISE EXCEPTION 'locked_seller_response_leaks_contact_or_note: %',v_row;
  END IF;

  PERFORM set_config('request.jwt.claim.sub','22222222-2222-4222-8222-222222222222',false);
  SELECT count(*) INTO v_count FROM public.get_seller_orders()
    WHERE id='cccccccc-cccc-4ccc-8ccc-cccccccccccc';
  IF v_count<>0 THEN RAISE EXCEPTION 'cross_seller_order_access'; END IF;
END
$test$;

UPDATE public.orders SET contact_unlocked=true
WHERE id='cccccccc-cccc-4ccc-8ccc-cccccccccccc';

DO $test$
DECLARE v_row text;
BEGIN
  PERFORM set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',false);
  SELECT phone||'|'||address||'|'||note INTO v_row FROM public.get_seller_orders()
    WHERE id='cccccccc-cccc-4ccc-8ccc-cccccccccccc';
  IF v_row IS DISTINCT FROM '0600000099|Test street|Call 0600000099' THEN
    RAISE EXCEPTION 'unlocked_seller_missing_private_note: %',v_row;
  END IF;
END
$test$;

INSERT INTO public.orders(id,payload,shop_id,seller_id,note,phone_verified,verification_expires_at)
VALUES ('dddddddd-dddd-4ddd-8ddd-dddddddddddd','{}'::jsonb,
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','11111111-1111-4111-8111-111111111111',
  'New fake note 0600000099',true,now()+interval '1 hour');

DO $test$
BEGIN
  IF (SELECT note FROM public.orders WHERE id='dddddddd-dddd-4ddd-8ddd-dddddddddddd') <> ''
     OR (SELECT note FROM private.order_notes WHERE order_id='dddddddd-dddd-4ddd-8ddd-dddddddddddd')
        IS DISTINCT FROM 'New fake note 0600000099' THEN
    RAISE EXCEPTION 'new_order_note_not_protected';
  END IF;
END
$test$;

UPDATE public.orders SET note='Updated private note' WHERE id='dddddddd-dddd-4ddd-8ddd-dddddddddddd';
DO $test$
BEGIN
  IF (SELECT note FROM public.orders WHERE id='dddddddd-dddd-4ddd-8ddd-dddddddddddd') <> ''
     OR (SELECT note FROM private.order_notes WHERE order_id='dddddddd-dddd-4ddd-8ddd-dddddddddddd')
        IS DISTINCT FROM 'Updated private note' THEN
    RAISE EXCEPTION 'updated_note_leaked_or_lost';
  END IF;
END
$test$;

UPDATE public.orders SET note='' WHERE id='dddddddd-dddd-4ddd-8ddd-dddddddddddd';
DO $test$
BEGIN
  IF EXISTS(SELECT 1 FROM private.order_notes WHERE order_id='dddddddd-dddd-4ddd-8ddd-dddddddddddd') THEN
    RAISE EXCEPTION 'blank_note_did_not_delete_private_copy';
  END IF;
END
$test$;

UPDATE public.orders SET note='Temporary note' WHERE id='dddddddd-dddd-4ddd-8ddd-dddddddddddd';
DELETE FROM public.orders WHERE id='dddddddd-dddd-4ddd-8ddd-dddddddddddd';
DO $test$
BEGIN
  IF EXISTS(SELECT 1 FROM private.order_notes WHERE order_id='dddddddd-dddd-4ddd-8ddd-dddddddddddd') THEN
    RAISE EXCEPTION 'private_note_was_not_cascaded_on_delete';
  END IF;
END
$test$;

\echo PASS isolated PostgreSQL note privacy: historic backfill, new/updated note scrub, private ACL, seller isolation, paid unlock, deletes.

-- BEFORE capture must not expose note in RETURNING or rewrite imported timestamps.
DO $test$
DECLARE r public.orders%ROWTYPE;
BEGIN
  INSERT INTO public.orders(id,payload,shop_id,seller_id,note,created_at,updated_at)
  VALUES ('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','{}',
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','11111111-1111-4111-8111-111111111111',
    'Returning must not leak 0600000099','2020-01-01','2021-01-01') RETURNING * INTO r;
  IF r.note<>'' OR r.created_at<>'2020-01-01' OR r.updated_at<>'2021-01-01' THEN
    RAISE EXCEPTION 'returning_leak_or_insert_timestamp_changed';
  END IF;
END
$test$;

-- A write from another trigger has depth >1; it must still be scrubbed.
CREATE FUNCTION private.test_nested_note() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO public.orders(id,payload,note)
  VALUES ('ffffffff-ffff-4fff-8fff-ffffffffffff','{}','Nested secret 0600000099');
  RETURN NEW;
END;
$$;
CREATE TABLE private.note_driver(id int);
CREATE TRIGGER nested_note AFTER INSERT ON private.note_driver
FOR EACH ROW EXECUTE FUNCTION private.test_nested_note();
INSERT INTO private.note_driver VALUES (1);
DO $test$
BEGIN
  IF (SELECT note FROM public.orders WHERE id='ffffffff-ffff-4fff-8fff-ffffffffffff')<>''
     OR (SELECT note FROM private.order_notes WHERE order_id='ffffffff-ffff-4fff-8fff-ffffffffffff')
       IS DISTINCT FROM 'Nested secret 0600000099' THEN
    RAISE EXCEPTION 'nested_trigger_note_leak';
  END IF;
END
$test$;

-- Rolling back a write must restore both public and private records.
BEGIN;
UPDATE public.orders SET note='rollback secret'
WHERE id='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
ROLLBACK;
DO $test$
BEGIN
  IF (SELECT note FROM private.order_notes WHERE order_id='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee')
     IS DISTINCT FROM 'Returning must not leak 0600000099' THEN
    RAISE EXCEPTION 'private_note_rollback_lost_original';
  END IF;
  IF has_function_privilege('anon','public.get_seller_orders()','EXECUTE') THEN
    RAISE EXCEPTION 'seller_rpc_exposed_to_anon';
  END IF;
END
$test$;

-- Exercise the actual RPC with a non-owner database role (not just JWT settings
-- while remaining superuser), and real denied direct table reads.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','22222222-2222-4222-8222-222222222222',false);
DO $test$
BEGIN
  IF EXISTS(SELECT 1 FROM public.orders) THEN RAISE EXCEPTION 'direct_cross_seller_leak'; END IF;
  IF EXISTS(SELECT 1 FROM public.get_seller_orders()) THEN
    RAISE EXCEPTION 'cross_seller_rpc_leak';
  END IF;
  BEGIN
    PERFORM note FROM private.order_notes;
    RAISE EXCEPTION 'direct_private_select_allowed';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END
$test$;
RESET ROLE;

-- An expired order must be hidden, never deleted by reading the dashboard.
UPDATE public.orders SET phone_verified=false,verification_expires_at=now()-interval '1 hour'
WHERE id='cccccccc-cccc-4ccc-8ccc-cccccccccccc';
SELECT set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',false);
SELECT count(*) FROM public.get_seller_orders();
DO $test$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.orders WHERE id='cccccccc-cccc-4ccc-8ccc-cccccccccccc') THEN
    RAISE EXCEPTION 'dashboard_read_deleted_historical_order';
  END IF;
END
$test$;
\echo PASS nested triggers, RETURNING, real roles, timestamps, rollback and non-destructive dashboard.

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',false);
DO $test$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.orders WHERE id='cccccccc-cccc-4ccc-8ccc-cccccccccccc') THEN
    RAISE EXCEPTION 'own_order_read_broken';
  END IF;
  IF EXISTS(SELECT 1 FROM public.orders WHERE note<>'') THEN RAISE EXCEPTION 'direct_note_leak'; END IF;
  BEGIN
    UPDATE public.orders SET contact_unlocked=true WHERE id='cccccccc-cccc-4ccc-8ccc-cccccccccccc';
    RAISE EXCEPTION 'seller_can_unlock_without_payment';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN
    PERFORM * FROM public.order_contacts;
    RAISE EXCEPTION 'direct_contact_leak';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END
$test$;
RESET ROLE;

DO $test$
BEGIN
  BEGIN
    INSERT INTO public.orders(id,payload,note)
    VALUES('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','{}','Ignored conflicting note')
    ON CONFLICT(id) DO NOTHING;
    RAISE EXCEPTION 'duplicate_id_not_rejected';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'order_id_already_exists' THEN RAISE; END IF; END;
  IF (SELECT note FROM private.order_notes WHERE order_id='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee')
    IS DISTINCT FROM 'Returning must not leak 0600000099' THEN
    RAISE EXCEPTION 'ignored_insert_overwrote_existing_private_note';
  END IF;
END
$test$;
