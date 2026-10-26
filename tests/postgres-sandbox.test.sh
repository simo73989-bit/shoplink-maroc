#!/usr/bin/env bash
set -Eeuo pipefail
trap 'rc=$?; echo "POSTGRES SANDBOX FAILED: line ${LINENO}, command: ${BASH_COMMAND}" >&2; exit "$rc"' ERR
# Ephemeral test database only. NEVER point PGHOST/PGDATABASE at Supabase production.
if [[ "${PGHOST:-}" != "localhost" || "${PGDATABASE:-}" != "shoplink_sandbox" ]]; then
  echo "REFUSING: this harness only runs against localhost database shoplink_sandbox" >&2
  exit 1
fi
PSQL=(psql -X -qAt -v ON_ERROR_STOP=1)
echo "[1/8] Load dummy schema and actual prepared migration"
[[ "$("${PSQL[@]}" -c "SELECT count(*) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema');")" == "0" ]] || { echo "REFUSING non-empty sandbox" >&2; exit 1; }
[[ "$("${PSQL[@]}" -c "SELECT current_setting('server_version_num')::int / 10000;")" == "17" ]] || { echo "PostgreSQL 17 required" >&2; exit 1; }
"${PSQL[@]}" -f tests/postgres-sandbox-fixture.sql >/dev/null
# Force a failure immediately before COMMIT: installation must be fully atomic.
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
if sed 's/^COMMIT;$/SELECT 1\/0; COMMIT;/' supabase/changes/01_order_idempotence_PREPARED.sql | "${PSQL[@]}" >"$tmpdir/rollback-01" 2>&1; then
  echo "FAILED injected migration error did not fail"; exit 1
fi
grep -q 'division by zero' "$tmpdir/rollback-01"
[[ "$("${PSQL[@]}" -c "SELECT to_regclass('public.order_create_attempts') IS NULL;")" == "t" ]]
[[ "$("${PSQL[@]}" -c "SELECT to_regprocedure('public.place_public_order_idempotent(uuid,uuid,text,text,text,text,text,text,jsonb)') IS NULL;")" == "t" ]]
"${PSQL[@]}" -f supabase/changes/01_order_idempotence_PREPARED.sql >/dev/null
echo "[2/8] Verify privileges and table RLS"
[[ "$("${PSQL[@]}" -c "select has_function_privilege('anon','public.place_public_order_idempotent(uuid,uuid,text,text,text,text,text,text,jsonb)','EXECUTE');")" == "t" ]]
[[ "$("${PSQL[@]}" -c "select has_table_privilege('anon','public.order_create_attempts','SELECT');")" == "f" ]]
[[ "$("${PSQL[@]}" -c "select relrowsecurity from pg_class where oid='public.order_create_attempts'::regclass;")" == "t" ]]
echo "[3/8] Concurrency: same UUID, same payload; only ONE order should be created"
QUERY="SELECT public.place_public_order_idempotent(
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid,
  'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'::uuid,
  'Demo Buyer','0612345678','Sale','Demo Street','Livraison','Test',
  '[{\"product_id\":\"cccccccc-cccc-4ccc-8ccc-cccccccccccc\",\"qty\":1}]'::jsonb
);"
"${PSQL[@]}" -c "$QUERY" >"$tmpdir/first" &
pid_a=$!
"${PSQL[@]}" -c "$QUERY" >"$tmpdir/second" &
pid_b=$!
wait "$pid_a"
wait "$pid_b"
cmp "$tmpdir/first" "$tmpdir/second" || { echo "FAILED same UUID returned different responses"; exit 1; }
[[ "$("${PSQL[@]}" -c "SELECT COUNT(*) FROM public.orders;")" == "1" ]]
[[ "$("${PSQL[@]}" -c "SELECT COUNT(*) FROM public.order_create_attempts;")" == "1" ]]
echo "[4/8] Exact retry reuses original result; changed payload gets conflict"
"${PSQL[@]}" -c "$QUERY" >"$tmpdir/retry"
cmp "$tmpdir/first" "$tmpdir/retry"
CHANGE_QUERY="$(printf '%s' "$QUERY" | sed 's/"qty":1/"qty":2/')"
if "${PSQL[@]}" -c "$CHANGE_QUERY" >"$tmpdir/conflict" 2>"$tmpdir/conflict.err"; then
  echo "FAILED changed payload should raise idempotency_conflict"; exit 1
fi
grep -q "idempotency_conflict" "$tmpdir/conflict.err"
[[ "$("${PSQL[@]}" -c "SELECT COUNT(*) FROM public.orders;")" == "1" ]]
echo "[rollback] Underlying RPC failure or invalid response must leave no order/marker"
for sentinel in FAIL_AFTER_INSERT INVALID_RESULT; do
  BAD_QUERY="$(printf '%s' "$QUERY" | sed "s/'Test'/'$sentinel'/;s/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee/")"
  if "${PSQL[@]}" -c "$BAD_QUERY" >"$tmpdir/bad-result" 2>&1; then
    echo "FAILED $sentinel unexpectedly succeeded"; exit 1
  fi
  if [[ "$sentinel" == "FAIL_AFTER_INSERT" ]]; then
    grep -q 'fixture_creation_failure' "$tmpdir/bad-result"
  else
    grep -q 'unexpected_order_result' "$tmpdir/bad-result"
  fi
  [[ "$("${PSQL[@]}" -c "SELECT count(*) FROM public.orders;")" == "1" ]]
  [[ "$("${PSQL[@]}" -c "SELECT count(*) FROM public.order_create_attempts;")" == "1" ]]
done
echo "[5/8] Deleted order must NOT be recreated by the original UUID"
"${PSQL[@]}" -c "DELETE FROM public.orders;" >/dev/null
[[ "$("${PSQL[@]}" -c "SELECT COUNT(*) FROM public.order_create_attempts WHERE order_id IS NULL;")" == "1" ]]
if "${PSQL[@]}" -c "$QUERY" >"$tmpdir/deleted" 2>"$tmpdir/deleted.err"; then
  echo "FAILED deleted order replay should be rejected"; exit 1
fi
grep -q "order_deleted" "$tmpdir/deleted.err"
[[ "$("${PSQL[@]}" -c "SELECT COUNT(*) FROM public.orders;")" == "0" ]]
echo "[6/8] Close legacy v2 API in disposable test DB and validate grants"
"${PSQL[@]}" -f supabase/changes/03_close_legacy_order_v2_AFTER_CUTOVER.sql >/dev/null
[[ "$("${PSQL[@]}" -c "SELECT has_function_privilege('anon','public.place_public_order_v2(uuid,text,text,text,text,text,text,jsonb)','EXECUTE');")" == "f" ]]
[[ "$("${PSQL[@]}" -c "SELECT has_function_privilege('authenticated','public.place_public_order_v2(uuid,text,text,text,text,text,text,jsonb)','EXECUTE');")" == "f" ]]
[[ "$("${PSQL[@]}" -c "SELECT has_function_privilege('anon','public.place_public_order_idempotent(uuid,uuid,text,text,text,text,text,text,jsonb)','EXECUTE');")" == "t" ]]
echo "[7/8] Close simulated legacy test OTP endpoints while keeping real OTP RPC allowed"
"${PSQL[@]}" -f supabase/changes/02_revoke_otp_test_AFTER_FRONTEND_RELEASE.sql >/dev/null
[[ "$("${PSQL[@]}" -c "SELECT has_function_privilege('anon','public.verify_order_phone_test_guest(uuid,text,text)','EXECUTE');")" == "f" ]]
[[ "$("${PSQL[@]}" -c "SELECT has_function_privilege('authenticated','public.verify_order_phone_test_guest(uuid,text,text)','EXECUTE');")" == "f" ]]
[[ "$("${PSQL[@]}" -c "SELECT has_function_privilege('authenticated','public.verify_order_phone_test(uuid,text)','EXECUTE');")" == "f" ]]
[[ "$("${PSQL[@]}" -c "SELECT has_function_privilege('authenticated','public.verify_order_phone(uuid)','EXECUTE');")" == "t" ]]
echo "[8/8] Wrapper still works as anon after old RPC permissions removed"
OTHER_QUERY="$(printf '%s' "$QUERY" | sed 's/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/dddddddd-dddd-4ddd-8ddd-dddddddddddd/')"
"${PSQL[@]}" -c "SET ROLE anon; $OTHER_QUERY" >"$tmpdir/anon-wrapper"
grep -q '"order_number"' "$tmpdir/anon-wrapper"
[[ "$("${PSQL[@]}" -c "SELECT COUNT(*) FROM public.orders;")" == "1" ]]
echo "[rollback] Failed note migration must restore notes, timestamps and trigger state"
"${PSQL[@]}" -c "INSERT INTO public.orders(id,payload,note,updated_at) VALUES('99999999-9999-4999-8999-999999999999','{}','Fake rollback note','2020-01-01');" >/dev/null
if sed 's/^COMMIT;$/SELECT 1\/0; COMMIT;/' supabase/changes/04_private_order_notes_PREPARED.sql | "${PSQL[@]}" >"$tmpdir/rollback-04" 2>&1; then
  echo "FAILED injected privacy migration error did not fail"; exit 1
fi
grep -q 'division by zero' "$tmpdir/rollback-04"
[[ "$("${PSQL[@]}" -c "SELECT to_regclass('private.order_notes') IS NULL;")" == "t" ]]
[[ "$("${PSQL[@]}" -c "SELECT note='Fake rollback note' AND updated_at='2020-01-01'::timestamptz FROM public.orders WHERE id='99999999-9999-4999-8999-999999999999';")" == "t" ]]
[[ "$("${PSQL[@]}" -c "SELECT tgenabled FROM pg_trigger WHERE tgname='orders_updated_at';")" == "O" ]]
"${PSQL[@]}" -c "DELETE FROM public.orders WHERE id='99999999-9999-4999-8999-999999999999';" >/dev/null
echo "[notes] Exercise server-side locked notes against temporary PostgreSQL tables"
"${PSQL[@]}" -f tests/private-order-notes.test.sql


echo "[payments] Compile and exercise the prepared payment ledger (no PSP)"
if sed 's/^COMMIT;$/SELECT 1\/0; COMMIT;/' supabase/changes/05_payment_sessions_PREPARED.sql | "${PSQL[@]}" >"$tmpdir/rollback-05" 2>&1; then
  echo "FAILED injected payment migration error did not fail"; exit 1
fi
grep -q 'division by zero' "$tmpdir/rollback-05"
[[ "$("${PSQL[@]}" -c "SELECT to_regclass('private.contact_payment_sessions') IS NULL;")" == "t" ]]
"${PSQL[@]}" -f tests/payment-sessions.test.sql
echo "[payments concurrency] 15 service requests must share one pending payment"
"${PSQL[@]}" -c "INSERT INTO public.orders(id,payload,shop_id,seller_id,phone_verified) VALUES('14141414-1414-4414-8414-141414141414','{}','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','11111111-1111-4111-8111-111111111111',true);" >/dev/null
PAY_QUERY="SET ROLE service_role; SELECT public.prepare_contact_payment('14141414-1414-4414-8414-141414141414','11111111-1111-4111-8111-111111111111','FAKE_TEST_ONLY','m1');"
payment_pids=()
for i in {1..15}; do
  "${PSQL[@]}" -c "$PAY_QUERY" >"$tmpdir/payment-$i" &
  payment_pids+=("$!")
done
for pid in "${payment_pids[@]}"; do wait "$pid"; done
for i in {2..15}; do cmp "$tmpdir/payment-1" "$tmpdir/payment-$i"; done
[[ "$("${PSQL[@]}" -c "SELECT count(*) FROM private.contact_payment_sessions WHERE order_id='14141414-1414-4414-8414-141414141414';")" == "1" ]]
echo "PASS — 15 actual PostgreSQL payment prepares, identical receipt, one pending row."
PAYMENT_ID="$("${PSQL[@]}" -c "SELECT id FROM private.contact_payment_sessions WHERE order_id='14141414-1414-4414-8414-141414141414';")"
"${PSQL[@]}" -c "SET ROLE service_role; SELECT public.save_contact_payment_session('$PAYMENT_ID','concurrent-session','https://sandbox.example/pay');" >/dev/null
EVENT_QUERY="SET ROLE service_role; SELECT public.apply_contact_payment_event(jsonb_build_object('provider','FAKE_TEST_ONLY','merchant_id','m1','event_id','concurrent-event','transaction_id','concurrent-transaction','payment_id','$PAYMENT_ID','order_id','14141414-1414-4414-8414-141414141414','session_id','concurrent-session','amount_minor',500,'currency','MAD','status','succeeded'));"
event_pids=()
for i in {1..15}; do
  "${PSQL[@]}" -c "$EVENT_QUERY" >"$tmpdir/event-$i" &
  event_pids+=("$!")
done
for pid in "${event_pids[@]}"; do wait "$pid"; done
[[ "$("${PSQL[@]}" -c "SELECT count(*) FROM private.contact_payment_events WHERE event_id='concurrent-event';")" == "1" ]]
[[ "$("${PSQL[@]}" -c "SELECT contact_unlocked FROM public.orders WHERE id='14141414-1414-4414-8414-141414141414';")" == "t" ]]
echo "PASS — 15 actual PostgreSQL callbacks, one committed event and one succeeded payment."

echo "PASS — full PostgreSQL sandbox completed (dummy backend only)."
