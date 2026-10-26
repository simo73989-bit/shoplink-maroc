# ShopLink Maroc — Supabase security audit (read-only)

Scope: `lcxwsowyqzbhmlpxijsu` (ShopLink Maroc ONLY). Audited from connector, without customer-row reads, SQL mutations, deployments, SMS or payments. Existing "ERROR" project was NOT touched.

## Verified against live PostgreSQL / edge function source

### Confirmed protections
- `orders`, `order_contacts` and `contact_unlock_payments` have RLS enabled; direct public access to private contacts/payments denied. `orders` SELECT is limited to authenticated sellers with the matching shop owner.
- `get_seller_orders()` returns masked phone and empty address until `contact_unlocked = true`. `get_seller_order_contact(uuid)` requires seller/shop owner + unlocked status.
- `verify_order_phone(uuid)` checks verified phone in Auth JWT against private contact, treats already verified orders idempotently, and decrements stock once under row locks.
- `request_contact_unlock(uuid)` verifies seller/shop ownership and phone verification, and reuses an existing pending payment ID on the same order. Orders are locked when modifying payment state.
- `finalize_contact_unlock_payment` / `fail_contact_unlock_payment` are NOT callable by `anon` or regular `authenticated` roles; the service role invokes them from the webhook.
- Webhook source enforces HMAC-SHA256 with a server secret and checks `status=succeeded`, `amount===5`, and `currency=MAD` before finalization.
- A unique index permits at most one `free`/`succeeded` payment per order.

### Confirmed blockers/risks
1. **HIGH: OTP test RPC** `verify_order_phone_test_guest(uuid,text,text)` is executable by `anon` and `authenticated`; `verify_order_phone_test(uuid,text)` is executable by `authenticated`. Their definitions accept a fixed test-code hash and can bypass actual SMS verification. Main production frontend still uses the guest test RPC. Staged revocation 02 is NOT deployed.
2. **HIGH: legacy order RPC bypasses idempotency wrapper.** `place_public_order_v2` is executable by `anon` and `authenticated`; API clients may call it directly, without the UUID lock. Stage migration 03 **after** new frontend release, never before. A new wrapper alone does not guarantee every legacy client is idempotent.
3. **HIGH: real payment gateway integration NOT demonstrated.** The `contact-unlock` Edge Function reads `CONTACT_PAYMENT_PROVIDER` and a static `CONTACT_PAYMENT_CHECKOUT_URL` and returns the URL; it does not create provider-specific, idempotent checkout sessions server-to-server. The webhook validates an application-level HMAC but includes no explicit event/timestamp replay protocol. Even though one *successful DB unlock* is enforced, this does not prove two external card charges cannot happen. Keep payment unlaunched until gateway contract, transaction idempotency, reconciliation and sandbox validation.
4. **MEDIUM: order note can expose contact before payment.** `get_seller_orders` returns `o.note` unchanged even if `contact_unlocked=false`. Browser/RLS masking protects `phone` and `address`, but a buyer can type contact coordinates into a note. A privacy fix would need a server-side policy/design decision, not a visual-only mask.
5. **MEDIUM: old browser tabs/cache.** After publishing SMS-only frontend, existing tabs might continue executing old code and call revoked test RPCs. Plan cache/version enforcement and an explicit safe cutover/maintenance window; never restore test OTP grants to "fix" older tabs.
6. **MEDIUM: account password leak protection disabled** per Supabase security advisor. Enable it in Auth Settings as a separate owner-authorized configuration change.
7. **LOW/REVIEW: SECURITY DEFINER findings** from Supabase advisors include intended public read APIs plus admin review RPCs. Reviewed `get_admin_reviews` / `admin_set_review_status` contain explicit `auth.uid()` and `public.is_platform_admin()` checks. All remaining broadly executable functions need a per-function authorization review; a linter WARN is not automatically an exploit.
8. **LOW/REVIEW: `product_policy_reason` search_path mutable**, check and fix according to advisor if relevant. Do not modify unrelated projects.
9. **MEDIUM: customer contact in browser sessionStorage** stored by immutable checkout until success; current branch redacts >24h stale attempts and blocks uncertain auto reorders, but third-party same-origin JS/XSS remains a concern. Improve CSP and sensitive field lifetime.
10. **MEDIUM: `get_seller_orders()` removes expired unverified rows as a side effect.** This requires careful reconciliation with idempotency tombstones when deploying migration 01.

## Validation status
- Previous GitHub Actions screenshot showed the isolated PostgreSQL 17 workflow green at commit `27d69d0`. This is an **ephemeral stub schema**, not the production backend. It validated compilation and representative concurrency/ACL tests, NOT real OTP or external charges.
- Further offline test scenarios for post-cutover 02/03 were added to the same GitHub Actions workflow after that screenshot. Their latest run result is **not yet independently confirmed**.
- Live read-only SQL verified role permissions, RLS/policies, and RPC definitions. We did NOT exercise any live order creation, live webhook event, or paid SMS.

## Safe release sequencing
1. Preserve an independently restorable backup and take an isolated database/staging environment with dummy data. A paid Supabase branch has not been created. Do not create paid resources without user approval.
2. Verify real Auth SMS delivery and provider configuration; eliminate guest test-code path in reviewed frontend. Audit old clients/versioning.
3. Apply prepared migration 01 to staging (not production). Test simultaneous requests, legacy and new RPC behavior, rate-limit paths, stock and RLS with dummy seller A/B.
4. Activate a payment provider **only** after its supported secure server-side checkout API, unique external attempt keys, webhook verification, anti-replay/event dedupe, sandbox double-charge/reconciliation tests.
5. After staging approval and backup, deploy production in order: migration 01 > SMS-only frontend > verify customer journey > migration 02 OTP test revoke > migration 03 legacy order-v2 revoke. Both 02 and 03 require safe open-tab/cache cutover planning.
6. Run read-only `has_function_privilege` checks for every post-cutover RPC, then check limited safe smoke tests. STOP/disable new orders if no safe rollback frontend exists. Never re-open OTP test function publicly.

## Owner-required decisions
- Does the seller need to see order `note` before paying, even if clients can type personal contact there? Recommend keeping purely product-related notes in a separate safe field, and keeping any free-text sensitive contact info private until unlock.
- Payment provider and test/sandbox account required for a real 5 MAD charging flow; avoid claiming the checkout is live until verified.

**This document is a security audit, not a deployment approval.**
