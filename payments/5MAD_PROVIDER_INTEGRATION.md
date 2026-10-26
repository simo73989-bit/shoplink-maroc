# ShopLink Maroc — 5 MAD online payment integration contract
**Prepared only; no gateway connected; no real money movement.**

## Current live behavior (verified from connected Supabase function source)
- `contact-unlock` checks seller authentication by calling `request_contact_unlock`, which checks shop ownership and that the customer's phone was verified.
- It reports `provider_configured:false` if environment variables `CONTACT_PAYMENT_PROVIDER` or `CONTACT_PAYMENT_CHECKOUT_URL` are not set. If they are set, it merely returns a STATIC configured checkout URL; it does **not** create an actual checkout session via any provider API.
- Frontend `sl41OpenPayment` appends `payment_id`, `order_id`, `amount=5` and `currency=MAD` in the browser URL. This must **never** count as authorization of the payable amount.
- The current `contact-payment-webhook` verifies HMAC-SHA256 using `CONTACT_PAYMENT_WEBHOOK_SECRET` and calls a service-role `finalize_contact_unlock_payment` RPC. No actual external PSP is currently configured to speak this ShopLink-specific signature protocol.
- DB finalization checks the amount 5.00 MAD and status, and unique index `contact_unlock_one_success_per_order_idx` prevents two successful **database unlock** rows per order. That does NOT prevent two successful **external card charges**. Existing provider charge and webhook replay protections are not proven.
- There were **0 successful contact-unlock payments** in the read-only audit dated 2026-10-26.

## Required selected merchant provider
Choose a licensed/acquiring merchant with card acceptance in Morocco, and obtain **sandbox** credentials and provider-specific signed callback docs. Current candidates (not endorsements):
- Payzone: online card acquiring and custom API, merchant onboarding/KYC. https://payzone.ma/faqs/
- NAPS ePay: hosted payment page and API with sandbox onboarding; public pack prices indicate **material setup/annual costs**, not a permanent 0 MAD integration. https://siteweb.naps.ma/entreprises/accepter-les-paiements/paiements-en-ligne/ and https://naps.ma/paiements-en-ligne/
- CMI: Moroccan e-commerce acquiring services, contract/merchant onboarding. https://www.cmi.co.ma/fr/solutions-paiement-ecommerce
- **Do NOT choose YouCan Pay for a fixed 5 MAD charge:** its official FAQ states a **10 MAD minimum transaction** although its no-setup/no-monthly-fees offer looks appealing. https://youcanpay.com/faq

Before committing to a provider: check whether it supports **5 MAD micropayments**, fees/minimum charges, refunds, merchant KYC (business registration), local currency MAD, and an API idempotency key. DO NOT share merchant API secrets in ChatGPT/GitHub.

## Backend adapter acceptance contract
1. On an authenticated seller request, resolve the owned `order_id`; require `phone_verified=true`. Never return private phone/address before successful verified payment.
2. Lock the `orders` row in DB. Reuse its single pending `payment_id`, rather than creating a new pending payment after every double click or HTTP timeout.
3. From a **server-side** authenticated Edge Function, call the *provider-specific sandbox checkout endpoint* with a hardcoded server-validated amount `5.00 MAD`, a stable merchant reference tied to the pending payment UUID, and the SAME provider idempotency key `payment_id` on retries.
4. Persist the provider checkout session ID / URL once in a private table with unique `payment_id`; reuse the stored session URL on subsequent requests. Never create sessions using query string values supplied by the browser.
5. Browser opens only the provider-issued hosted checkout URL. Never collect raw card number/CVV in ShopLink HTML.
6. Authenticate incoming provider webhooks by the **provider's official signature verification scheme**, bound to the raw body and proper key/timestamp. The provider will not automatically generate ShopLink-specific `x-shoplink-signature`.
7. Check exact PSP merchant ID, order/payment reference, currency `MAD`, amount **5.00** in the PSP's documented units, success/captured status and the provider's unique transaction ID. Query the PSP's transaction-status API on unclear notifications if supported.
8. Deduplicate webhook events by `provider,event_id`; enforce uniqueness of `provider_transaction_id` and prevent matching a transaction to another seller/order. Log suspicious second success as refund/reconciliation case, NOT a second unlock.
9. Return success to seller only after an independently authenticated provider confirmation and committed DB transaction. On ambiguous network responses, use PSP transaction-status lookup and same idempotency key; NEVER initiate a second charge blindly.
10. Provider sandbox tests: 15 concurrent checkout clicks, lost provider session response, one charge, duplicate signed callback, invalid signature, changed amount, wrong currency, wrong seller, replayed provider ID across orders, refund, provider 500/timeout, stale open tabs.

## Current test artifacts
- `tests/payment-gateway-contract-sandbox.test.cjs` simulates the above rules with **fake** PSP behavior and no network/charge. It can be run using:
  `node tests/payment-gateway-contract-sandbox.test.cjs`
- `.github/workflows/shoplink-postgres-sandbox.yml` now runs that test in CI.
- These tests are specifications; they do NOT constitute an integration with Payzone, NAPS, CMI or another provider.

## GO / NO-GO
- Real 5 MAD charging: **NO-GO** until merchant PSP selected, credentials safely installed in Supabase function secrets, its official API implemented, sandbox tests and external charge reconciliation independently verified.
- Current fake/placeholder `CONTACT_PAYMENT_CHECKOUT_URL` must NOT be used for real charging.
- OTP was explicitly deferred by the product owner: **do not turn on card payments in production while phone verification remains disabled and test-code RPC access remains exposed**.
