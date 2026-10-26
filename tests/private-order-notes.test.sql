-- Disposable PostgreSQL only; fake buyers, fake phones, fake shop owners.
\set ON_ERROR_STOP on

INSERT INTO public.shops(id,owner_id)
VALUES ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','11111111-1111-4111-8111-111111111111'),
       ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','22222222-2222-4222-8222-222222222222');

-- This order was created before the privacy migration and contains a raw contact in note.
INSERT INTO public.orders(id,payload,shop_id,seller_id,customer_name,phone,city,note,
  phone_verified,verification_expires_at)
VALUES ('cccccccc-cccc-4ccc-8ccc-cccccccccccc','{}'::jsonb,
 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','11111111-1111-4111-8111-111111111111',
 'Fake Customer','061*****99','Sale','Call 0600000099',true,now()+interval '1 hour');
INSERT INTO public.order_contacts(order_id,phone,address)
VALUES ('cccccccc-cccc-4ccc-8ccc-cccccccccccc','0600000099','Test street');

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
  IF v_row IS DISTINCT FROM '061*****99||' THEN
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
