# ShopLink Maroc — security release plan (prepared, NOT deployed)

**Status:** staging testing required. Production `main`, Supabase and Vercel have NOT been modified.

## Confirmed backend facts (read-only Supabase inspection)
- Target project ID: `lcxwsowyqzbhmlpxijsu` — never use the other connected projects.
- PostgreSQL 17.6; `extensions.digest(text,text)` and `public.place_public_order_v2(uuid,text,text,text,text,text,text,jsonb)` exist.
- `public.order_create_attempts` does not exist yet. Neither `anon` nor `authenticated` can `CREATE` objects in `public`.
- Direct RLS access to `order_contacts` is blocked. `get_seller_orders()` returns masked contact before unlock.
- `verify_order_phone(uuid)` checks the authenticated JWT phone against the order contact, is idempotent on already-verified orders, and decrements stock transactionally.
- **`verify_order_phone_test_guest` is STILL callable by anonymous users in production.** The current `main` frontend still calls it. DO NOT revoke it without deploying a compatible SMS-only frontend first.
- Payment functions check shop ownership and OTP; webhook verifies an HMAC and amount/currency. Actual payment gateway configuration, provider idempotency, webhook anti-replay and external charge reconciliation are NOT verified.

## Protected changes in this branch
- `index.html` now persists a **single immutable request UUID and exact RPC payload** (`phase: pending`) before contacting the server; it fails closed if sessionStorage cannot store and read the record. Simultaneous same-page submissions are locked.
- On successful order RPC response, `phase: created` plus order receipt and OTP resume information are durably saved **before** cart clearing or DOM updates. A failed render cannot erase the receipt.
- On response loss, retry uses the same UUID and saved RPC payload even if catalog price/name changed. A pending attempt is not silently replaced.
- On reload, created-order OTP state is recoverable from the saved attempt, and the public tracking RPC is queried before asking for another SMS.
- After SMS Auth accepts the code, the temporary OTP access token is held **in memory only** until `verify_order_phone` confirms. If that RPC response is lost, the frontend immediately checks `track_public_order`; if still unresolved, a retry can reuse the accepted SMS session while the same page remains open. A full refresh cannot recover a lost in-memory JWT: this still requires explicit UX/test validation.
- Business response `ok` and `phone_verified` are checked, not just HTTP 200.
- The prepared SQL wrapper uses a transaction-scoped advisory lock, direct SHA-256 payload digest, and a tombstone (`ON DELETE SET NULL`) so deleting an order does not allow the same UUID to recreate it.
- Idempotency response is allowlisted to non-contact fields; RLS is enabled and direct table access is revoked.
- Old `place_public_order_v2` remains callable and is **not** idempotency-key protected for legacy clients.

## RELEASE GATES — do not skip or reorder
1. **Backup and isolation:** create/verify a restorable backup and rollback process. Test with an isolated DB and dummy products/phones; never live customer data. A paid Supabase staging branch has NOT been created and local Docker was explicitly abandoned. Without an isolated database, stop before DDL.
2. **Staging migration 01:** apply `01_order_idempotence_PREPARED.sql` in one DB transaction. It creates `order_create_attempts` and a NEW RPC without replacing v2. Verify the schema and effective grants. If it fails, rollback the transaction; do not continue.
3. **Staging integration:** run parallel identical UUID requests (expect one order), retry after lost response (same order ID), same UUID with altered payload (`idempotency_conflict`), deleted order + UUID replay (`order_deleted`), invalid product/price/stock, rate limits, customer contact masking, vendor A/B RLS, real SMS sandbox, Auth JWT phone matching, and payment provider sandbox without real money. Exercise storage-disabled frontend and interrupted DOM render.
4. **Staging release test:** deploy the branch frontend against staging and test complete customer checkout and seller/admin flows. Verify payment processor checkout session reuse, webhook HMAC, event idempotency, real amount 5 MAD and prevention of second external charge. Test performance/accessibility and physical receipt printer separately.
5. **Production migration 01:** only AFTER staging approval and verified backup, apply migration 01 to **ShopLink Maroc production**; verify function exists, its grants are expected and old `place_public_order_v2` still works. No production test that creates customer orders without explicit authorization.
6. **Production frontend:** deploy audited frontend AFTER production RPC is present. Smoke-test new order creation, retry, OTP, contact lock, dashboard, exports. Keep a maintenance/disable-orders plan if smoke checks fail.
7. **OTP security closure:** once ONLY the SMS-only frontend is confirmed in production, apply `02_revoke_otp_test_AFTER_FRONTEND_RELEASE.sql` in one transaction. Verify `has_function_privilege` returns false for `anon` and `authenticated` on both test RPCs, and true for authenticated users on real `verify_order_phone(uuid)`. Check no other overloads or integrations still expose test verification.
8. **Monitor and sign off:** watch order-create HTTP errors, duplicate IDs, OTP verification recovery, masked contacts, SMS throttling, payment events and refunds. NO production-ready declaration without real backend tests.

## ROLLBACK — explicit sequence
- **Before migration 01:** no frontend deployment or database rollback required.
- **If migration 01 fails:** it is transactional; rollback its transaction, diagnose offline; do not deploy the new frontend.
- **After migration 01 but before frontend:** leave the additive RPC/table in place, old code continues using v2; no data restoration needed.
- **After new frontend but before migration 02:** rollback the frontend to a previously reviewed **real-SMS-only** compatible build (e.g. commit `70cf8f8dbc3875bb6114795b88ccb6f3930988a4`, if verified in staging), or disable new orders while repairing. NEVER assume the old `main` is safe.
- **After migration 02:** never roll back to original `main`, which invokes the revoked guest OTP test RPC. Roll back only to a confirmed SMS-only frontend. DO NOT regrant PUBLIC/anon access to test RPCs to repair checkout; disable new orders temporarily if no safe frontend is available.
- Do not drop attempt tombstones or restore an older DB snapshot over newly received production orders/payments. Reconcile individually.
- Preserve existing payment webhook and transactions while debugging. A rollback must not re-charge clients.

## Further constraints and cautions
- The browser keeps immutable order parameters in **sessionStorage**, including buyer contact. As of this revision, abandoned attempts older than **24 hours** are redacted to a `stale` marker with only UUID and timestamp, and checkout is blocked instead of automatically creating a new potentially duplicate order. This is limited to the tab and not XSS-proof; hardening CSP and preventing third-party scripts remains necessary.
- Browser sessionStorage can be cleared by the user, so no client-only scheme can promise a stable UUID after arbitrary clearing. Server-side rate limits, account/order reconciliation, and old-v2 retirement still matter.
- The server-stored idempotency marker has no automatic expiry. Define a retention window that exceeds the maximum documented replay lifetime; never delete markers while the same UUID can replay.
- Both test OTP RPCs still exist in production pending a safe release. Read-only live ACL checks CONFIRM that `verify_order_phone_test_guest` is executable by `anon` and `authenticated`, and `verify_order_phone_test` by `authenticated`. Their existence is a security risk. The old v2 creation RPC is still executable by `anon` and `authenticated`; new-client idempotency does not secure direct legacy RPC calls.
- Prepared SQL has not been parsed/run on a real PostgreSQL staging database. A Codex audit identified a missing PL/pgSQL `END;` semicolon and it was corrected in GitHub; the corrected SQL still requires isolated execution and privilege tests. Frontend scripted tests use mocks; no SMS, payments, DDL or production data mutations were made.

## Tests currently run
- Parsed 14 inline JavaScript scripts; original CSS blocks unmodified.
- Mocked same-page double submit (one request), changed catalog after response loss (same UUID and unchanged payload), unavailable sessionStorage (no request), render exception after successful creation (receipt + OTP still retained), storage loss on retry (fail-closed), and aged abandoned attempt (PII removed after 24h; no automatic replacement request).
- Mocked accepted Auth SMS + ambiguous order-RPC: authoritative tracking confirmed success, or retry re-used the same in-memory token without a second Auth request; persistent server failure produced no false success.
- These tests do NOT establish PostgreSQL concurrency safety, RLS, payment charges, real SMS delivery or mobile/browser compatibility.

## Additional blockers verified after the second Codex audit
- **P1 SQL syntax fixed**: `END;` now terminates the PL/pgSQL function body. Static check alone cannot prove compilation on real PostgreSQL.
- The 5 MAD backend pending payment is serialized on the same order row and reuses the existing pending payment ID, but the external gateway session and prevention of multiple **actual card charges** remain unproven. The exposed checkout link must NOT be considered a verified provider integration.
- SMS Auth response loss after the provider consumed the OTP cannot be reliably recovered without an issued access token; instruct the buyer to request a new SMS if server-side tracking does not show confirmed status.
- A previously open tab can keep executing the original frontend after Vercel deployment. Plan cache/version enforcement and a safe migration window BEFORE closing test OTP RPCs; never leave an old-tab-only bypass enabled permanently.


## Private order notes — additional prepared migration 04

**NOT DEPLOYED**: \`supabase/changes/04_private_order_notes_PREPARED.sql\`.

Read-only live inspection confirmed that \`public.orders.note\` holds the raw buyer note; \`get_seller_orders()\` returns it even when \`contact_unlocked=false\`. A seller can also query their own raw \`orders.note\` via their existing orders SELECT policy. CSS hiding does **not** protect this data.

Migration 04 is designed to:
1. Create \`private.order_notes\` (RLS on; \`anon\` and \`authenticated\` have no schema usage or direct table access) with a FK to \`orders\`.
2. Migrate historical raw notes to the private table inside one transaction and scrub \`public.orders.note\`. Existing \`orders_updated_at\` triggers may update historical \`updated_at\` values; evaluate that before production.
3. Install an AFTER INSERT/UPDATE trigger to capture new/changed buyer notes and empty the public note column before the transaction commits. Empty notes also delete the private copy.
4. Replace \`get_seller_orders()\` with an identically typed result, returning the private note to the right seller **only when \`contact_unlocked=true\`**, keeping existing contact masking and owner checks.
5. Keep frontend markup, logo and layout unchanged. Buyer still submits the same note input.

The private-note test suite \`tests/private-order-notes.test.sql\` runs on ephemeral PostgreSQL 17 in GitHub Actions and checks historical backfill, locked/unlocked seller responses, cross-seller access, direct table scrub, update/clear, deletion cascades and private table grants. **Current revised test run has not yet been independently confirmed green**: verify GitHub Actions workflow before any backend rollout.

This protects the buyer's \`note\` free text in the orders table; it does not prove that every other free-text field (\`customer_name\`, \`city\`, \`items[].name\`) could never contain an encoded phone number. Decide whether to mask or validate those fields too if claiming a strict no-PII-before-payment guarantee.

**Migration order:** stage 04 and test with the real Supabase schema/triggers; validate seller order rendering and whitelisted/free unlock, payment unlock, and historic updated_at semantics. Only then consider production 04 after backup, independently from the OTP/payment rollout. If rollback is needed, **never repopulate \`public.orders.note\` with private notes**, which would restore the leak.
