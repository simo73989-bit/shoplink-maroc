#!/usr/bin/env bash
set -euo pipefail
# Ephemeral test database only. NEVER point PGHOST/PGDATABASE at Supabase production.
if [[ "${PGHOST:-}" != "localhost" || "${PGDATABASE:-}" != "postgres" ]]; then
  echo "REFUSING: this harness only runs against localhost disposable PostgreSQL test DB" >&2
  exit 1
fi
PSQL=(psql -X -qAt -v ON_ERROR_STOP=1)
echo "[1/6] Load dummy schema and actual prepared migration"
"${PSQL[@]}" -f tests/postgres-sandbox-fixture.sql >/dev/null
"${PSQL[@]}" -f supabase/changes/01_order_idempotence_PREPARED.sql >/dev/null
echo "[2/6] Verify privileges and table RLS"
[[ "$("${PSQL[@]}" -c "select has_function_privilege('anon','public.place_public_order_idempotent(uuid,uuid,text,text,text,text,text,text,jsonb)','EXECUTE');")" == "t" ]]
[[ "$("${PSQL[@]}" -c "select has_table_privilege('anon','public.order_create_attempts','SELECT');")" == "f" ]]
[[ "$("${PSQL[@]}" -c "select relrowsecurity from pg_class where oid='public.order_create_attempts'::regclass;")" == "t" ]]
echo "[3/6] Concurrency: same UUID, same payload; only ONE order should be created"
QUERY="SELECT public.place_public_order_idempotent(
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid,
  'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'::uuid,
  'Demo Buyer','0612345678','Sale','Demo Street','Livraison','Test',
  '[{\"product_id\":\"cccccccc-cccc-4ccc-8ccc-cccccccccccc\",\"qty\":1}]'::jsonb
);"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
"${PSQL[@]}" -c "$QUERY" >"$tmpdir/first" &
pid_a=$!
"${PSQL[@]}" -c "$QUERY" >"$tmpdir/second" &
pid_b=$!
wait "$pid_a"
wait "$pid_b"
cmp "$tmpdir/first" "$tmpdir/second" || { echo "FAILED same UUID returned different responses"; exit 1; }
[[ "$("${PSQL[@]}" -c "SELECT COUNT(*) FROM public.orders;")" == "1" ]]
[[ "$("${PSQL[@]}" -c "SELECT COUNT(*) FROM public.order_create_attempts;")" == "1" ]]
echo "[4/6] Exact retry reuses original result; changed payload gets conflict"
"${PSQL[@]}" -c "$QUERY" >"$tmpdir/retry"
cmp "$tmpdir/first" "$tmpdir/retry"
CHANGE_QUERY="$(printf '%s' "$QUERY" | sed 's/"qty":1/"qty":2/')"
if "${PSQL[@]}" -c "$CHANGE_QUERY" >"$tmpdir/conflict" 2>"$tmpdir/conflict.err"; then
  echo "FAILED changed payload should raise idempotency_conflict"; exit 1
fi
grep -q "idempotency_conflict" "$tmpdir/conflict.err"
[[ "$("${PSQL[@]}" -c "SELECT COUNT(*) FROM public.orders;")" == "1" ]]
echo "[5/6] Deleted order must NOT be recreated by the original UUID"
"${PSQL[@]}" -c "DELETE FROM public.orders;" >/dev/null
[[ "$("${PSQL[@]}" -c "SELECT COUNT(*) FROM public.order_create_attempts WHERE order_id IS NULL;")" == "1" ]]
if "${PSQL[@]}" -c "$QUERY" >"$tmpdir/deleted" 2>"$tmpdir/deleted.err"; then
  echo "FAILED deleted order replay should be rejected"; exit 1
fi
grep -q "order_deleted" "$tmpdir/deleted.err"
[[ "$("${PSQL[@]}" -c "SELECT COUNT(*) FROM public.orders;")" == "0" ]]
echo "[6/7] Close legacy v2 API in disposable test DB and validate grants"
"${PSQL[@]}" -f supabase/changes/03_close_legacy_order_v2_AFTER_CUTOVER.sql >/dev/null
[[ "$("${PSQL[@]}" -c "SELECT has_function_privilege('anon','public.place_public_order_v2(uuid,text,text,text,text,text,text,jsonb)','EXECUTE');")" == "f" ]]
[[ "$("${PSQL[@]}" -c "SELECT has_function_privilege('authenticated','public.place_public_order_v2(uuid,text,text,text,text,text,text,jsonb)','EXECUTE');")" == "f" ]]
[[ "$("${PSQL[@]}" -c "SELECT has_function_privilege('anon','public.place_public_order_idempotent(uuid,uuid,text,text,text,text,text,text,jsonb)','EXECUTE');")" == "t" ]]
echo "[7/7] Wrapper still works as anon after old RPC permissions removed"
OTHER_QUERY="$(printf '%s' "$QUERY" | sed 's/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/dddddddd-dddd-4ddd-8ddd-dddddddddddd/')"
"${PSQL[@]}" -c "SET ROLE anon; $OTHER_QUERY" >"$tmpdir/anon-wrapper"
grep -q '"order_number"' "$tmpdir/anon-wrapper"
[[ "$("${PSQL[@]}" -c "SELECT COUNT(*) FROM public.orders;")" == "1" ]]
echo "PASS — PostgreSQL real concurrent retries, RLS, tombstones, legacy RPC closed, wrapper accessible to anon."
