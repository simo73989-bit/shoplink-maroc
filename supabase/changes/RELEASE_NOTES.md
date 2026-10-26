# ShopLink Maroc — prepared corrections, no production deployment

Work branch: `fix/shoplink-security-otp-20261025`. Production, `main`, live orders,
Supabase project `lcxwsowyqzbhmlpxijsu`, SMS and real payments are untouched.
OTP setup is deferred. Payment provider is not selected/configured. A real backup
has NOT been created: owner reports Session Pooler authentication failure.

## Corrections and validation boundary

- Checkout persists one immutable UUID and exact RPC arguments before sending.
  Same-page double submission is guarded. Reload and response loss reuse the record;
  changed cart/quantity never silently replaces uncertain RPC arguments. Corrupt
  records now block new order creation. A failed receipt write retains the pending
  UUID. Abandoned records are redacted on access after 24 hours and block automatic
  reordering; this is not a background deletion guarantee for inactive tabs.
- The new SQL wrapper serializes the same UUID, saves only an allowlisted receipt,
  rejects changed arguments and preserves tombstones after order deletion. Invalid
  backend receipts now roll back instead of leaving an unusable attempt marker.
- Migration 04 captures notes BEFORE writing, with a deferred FK. It removes the
  trigger-depth bypass, recursive timestamp changes and raw-note `RETURNING` leak.
  Historical backfill locks the table before reading, preserves every other order
  field and restores the exact original updated-at trigger mode. Its seller RPC
  uses a fixed locked-phone mask and has explicit ACLs. Dashboard reads no longer
  physically delete expired orders; they keep the previous visibility filter.
- CSV contact masking/formula protection is regression-tested. No layout, CSS or
  logo changes. Other user-controlled fields (name/city/items) are not a complete
  DLP boundary: a determined customer can encode coordinates in arbitrary text.
  Do not claim universal prevention of PII in all fields; review field policy and
  every direct-table/view/RPC path against an isolated real-schema clone.
- Payment double clicks are guarded. The browser opens the server-issued HTTPS
  checkout URL unchanged; it no longer invents amount/reference query parameters.
- Migration 05 and `supabase/functions/` are NEW PREPARED replacements, not downloaded
  copies of deployed functions. The repository did not contain their deployed SQL
  or Edge sources. The payment core uses fixed 500 MAD minor units, a stable payment
  UUID, provider-native signature interface and independent status lookup. It rejects
  unconfigured/non-sandbox adapters. **No official provider adapter is implemented.**
- Its separate private ledger has service-only RPCs, one lifetime attempt per order,
  atomic events, transaction/event uniqueness, terminal-state checks and refund
  re-locking. Failed/cancelled/refunded attempts cannot automatically start a new
  charge; reconciliation and a reviewed future retry policy are required. Re-locking
  cannot revoke contact information a seller already learned. Never run this ledger
  alongside the legacy finalizer for the same order. Schema/billing/dashboard and
  whitelist integration remains a gate, not a production-ready replacement.
- Backup helper uses verified TLS, both PostgreSQL 17 tools, unique partial files,
  cleanup on any validation failure, one connection attempt, environment restoration
  and a refusal to write inside Git. A readable archive catalog is NOT a verified
  restore. The archive is not automatically encrypted; protect/encrypt it locally.

## Test commands

```
node tests/checkout-recovery.test.cjs
node tests/payment-gateway-contract-sandbox.test.cjs
pwsh -NoProfile -File tests/backup-helper.test.ps1
deno check supabase/functions/contact-unlock/index.ts supabase/functions/contact-payment-webhook/index.ts
deno test --allow-env=CONTACT_PAYMENT_ALLOWED_ORIGIN tests/payment-edge.test.ts
PGHOST=localhost PGDATABASE=shoplink_sandbox PGUSER=postgres bash tests/postgres-sandbox.test.sh
```

The shell harness requires an EMPTY, disposable PostgreSQL 17 database named
`shoplink_sandbox`. It installs dummy schemas and dummy old RPCs. Never point it at
Supabase, a tunnel to production, or an existing development database. The Actions
service creates this database automatically. Cloud tasks are already isolated:
use the current checkout; no extra Git worktree is needed.

Local real PostgreSQL 17.11 checks cover actual wrapper locks, transaction rollback,
replay/conflict/tombstone, RLS/roles, migration rollback, note preservation, nested
triggers, RETURNING, historical timestamps, direct access, and 15 concurrent payment
prepares. **The underlying order RPC and OTP are fixtures, not production code.**
Stock deduction, real product pricing/rate limits, production triggers, real SMS and
external charges are NOT validated by these tests. JS tests use mocks; PowerShell
tests use fake tools and no connection. Edge tests run without network permission.

Audit correction: PostgreSQL 17 accepts the outermost function body's final `END`
without a semicolon. The exact migration 01 from `eb2c482` compiled locally. The
previous report identifying that as a confirmed syntax error was incorrect. `END;`
remains conventional syntax, not evidence of a formerly broken migration.

## Publication gates and order — future owner-authorized work only

1. Resolve backup authentication locally without password reset or repeated retries.
   Obtain a privately protected archive including private schemas/notes and verify
   an isolated restore. Capture roles, secrets/configuration and storage separately.
2. Obtain a sanitized real-schema/trigger/function snapshot and test 01/04/05 against
   it in isolation, including existing orders, stock, seller A/B and rollback. The
   dummy fixture cannot certify production compatibility. Inventory all overloaded
   order/OTP/payment RPCs and inherited grants; sources in old audit docs are historic
   observations, not a fresh live verification.
3. Migration 04 is an independent privacy rollout after backup and real-schema
   testing. Validate every seller API/export and INSERT/UPDATE/RETURNING path. Review
   callers using deferred-constraint changes, duplicate-ID inserts/upserts and other
   order-writing triggers before rollout. Retain private notes if rollback is needed.
4. Keep OTP deferred and production blocked. Do not deploy the SMS-only checkout as a
   complete flow until official SMS sandbox, JWT matching, response loss and stock
   tests pass. Never restore or introduce a test-code verification bypass.
5. Order rollout, once OTP is validated: migration 01 first, compatible frontend
   second, then migration 02 (test OTP closure), then 03 (legacy v2 closure). Stage
   each separately. Account for open tabs/caches; enforce a safe maintenance/version
   cutover. An old tab must fail safely, not retain insecure RPC access indefinitely.
6. Payment rollout is separate and still blocked: select a licensed merchant provider
   accepting **5 MAD**, implement and review its OFFICIAL sandbox API/signatures,
   provision sandbox credentials securely, test idempotency/refunds/reconciliation,
   reconcile existing legacy pending attempts, and validate ledger integration.
   Only then consider migration 05 and the prepared endpoints against staging.
   No static URL or ShopLink-owned generic HMAC is a real provider integration.
7. Verify branch CI at the final commit, secure a tested compatible rollback build,
   and obtain production approval. Nothing in this branch authorizes production DDL,
   deployment, SMS or charging. No production-ready declaration until all gates pass.

## Rollback

- A failed 01/04/05 transaction must roll back fully; injected-failure tests exercise
  01 and 04, and normal event transactions preserve payment integrity.
- After additive 01, retain its RPC/table/tombstones. Do not erase UUID history or
  restore an old snapshot over new orders/payments.
- After 04, keep private notes; never copy them back into seller-readable raw fields.
  Fix forward or use a verified privacy-compatible build/function definition. Do not
  reintroduce dashboard deletion as a rollback shortcut.
- After 02/03, only a staged SMS-only, idempotent compatible frontend can be used.
  Otherwise disable new orders. Do not regrant insecure test/legacy RPC access.
- Payment rollback disables checkout creation but preserves ledger, event history,
  PSP reconciliation and authenticated webhook processing. Never recharge to repair
  a lost response; refund/reconcile individual external transactions.
