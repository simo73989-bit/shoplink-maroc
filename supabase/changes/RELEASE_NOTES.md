# ShopLink Maroc — controlled release notes

Status: **PREPARED, NOT DEPLOYED**. Production `main`, Supabase database and Vercel were not changed in this patch.

## Preconditions
1. Create a recent, verifiable database backup and a rollback procedure. Do not use live customer records for tests.
2. Use an isolated Supabase project/branch when possible (not created here). Test against a clone of schema with dummy shops/products/orders.
3. Verify the `extensions.digest` function exists in staging, the prepared SQL parses and `place_public_order_v2` is intact.
4. Verify current real SMS Auth, CORS, payment provider checkout, signed webhook and rate limiting. Frontend mocks cannot prove any of these.
5. Check any additional clients/integrations still calling `verify_order_phone_test_guest` or `verify_order_phone_test`.

## Deployment order
1. Apply and validate `supabase/changes/01_order_idempotence_PREPARED.sql` to staging. It creates `place_public_order_idempotent` but does not change the existing v2 endpoint.
2. Run two parallel requests with the SAME request UUID, payload and dummy products; both must return the same order ID with ONE row. Run with same UUID and a DIFFERENT payload; it must reject with `idempotency_conflict`. Drop an HTTP response, retry the same UUID and verify identical result.
3. Verify RLS isolation, masked contact in real API responses, `track_public_order` access with reference+phone, OTP already-verified responses and stock changes once only. Exercise two browsers/phones and SMS 429.
4. Deploy the reviewed `index.html` only after the idempotent RPC is present in production. The frontend expects that new RPC.
5. ONLY AFTER the new frontend is live, apply `supabase/changes/02_revoke_otp_test_AFTER_FRONTEND_RELEASE.sql` to remove unauthenticated/test-code verification access. Check real OTP flow immediately. Production `main` currently depends on the old guest test function and MUST NOT be left calling it after permissions are revoked.
6. Re-run security/transaction/payments checks before declaring production ready.

## Notes and unresolved risks
- No isolated staging was created (paid Supabase branch and local Docker were deliberately avoided).
- Prepared migration is unexecuted; SQL syntax, concurrency and rollback require real database validation.
- The frontend restoration uses `track_public_order` to check whether the order is already verified. Avoid revealing order information with order ID alone; track requires reference and full phone.
- Keep `order_create_attempts` private with RLS; never grant direct Data API access. A successful request UUID replay must return the original order result.
- The existing `place_public_order_v2` API remains callable; apps using that old endpoint do not benefit from idempotency. Consider API migration/deprecation.
- The legacy payment Edge Functions check HMAC and RPC authorizations, but real gateway configuration, secret management, anti-replay, reconciliation, refunds and payment-provider contracts remain unverified.
- Server-side OTP send rate limits across browsers, devices and IPs must be tested; client locks are not sufficient.
- No actual customer SMS, live payment, DDL or data mutations were performed.

## Test report
Static checks: 14 inline JavaScript blocks parsed without syntax errors; CSS blocks unchanged; new idempotent RPC, stable request UUID storage and order-status reconciliation paths present. These are NOT full integration tests. No merge or deploy should occur solely on this basis.
