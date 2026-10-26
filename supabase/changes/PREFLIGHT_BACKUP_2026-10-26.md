# ShopLink Maroc — backup and migration-04 preflight
Date: 2026-10-26 | **READ-ONLY CHECK COMPLETED, BACKUP NOT YET CREATED**

Target project: `lcxwsowyqzbhmlpxijsu` (ShopLink Maroc only). No production SQL changed.

## Verified read-only snapshot (aggregate information only)

| Preflight item | Observed |
|---|---|
| Existing orders | 1 |
| Orders with a non-empty buyer note | 1 |
| Those notes for already-unlocked orders | 1 |
| Notes for locked orders | 0 |
| Contact-unlock payment attempts | 2 |
| Pending payment attempts | 1 |
| Succeeded payment attempts | 0 |
| Table `private.order_notes` | Not yet installed |
| Function `public.get_seller_orders()` definition checksum (MD5) | `a427aac1eba0b72bbc94a1aadfcc3e1c` |
| Existing triggers on `public.orders` | `orders_updated_at`, `trg_cancel_risk`, `trg_notify_verified_order`, `trg_order_delete_risk`, `trg_sync_order_tenant` |

These counts and checksums are **NOT a database backup**. No personal data was copied or committed.

## Required real backup before touching production

1. In Supabase Dashboard, open **ShopLink Maroc → Database → Backups**. If a current restorable backup exists on the project's paid plan, document date/coverage and verify recovery options before migration. **Do not click Restore**. The project plan was not verified by the connector.
2. If the Dashboard lacks restorable backups, make an independent **encrypted full logical backup** (schema and data) under your own private control. Supabase recommends `supabase db dump` for Free projects; CLI dumps run via a container. Alternative direct `pg_dump` can be used from a trusted client with a compatible Postgres version and secure read-only connection, but complete Supabase restore requires capturing roles, app schemas and other project-specific components. Do not attempt an ad hoc incomplete backup and call it restorable.
3. Confirm backup file sizes and that an isolated restore (not over the live database!) loads successfully before marking the backup verified.
4. Keep DB connection strings, dump contents, note/contact rows, service-role keys and merchant credentials **off GitHub**, especially since this repo is public.
5. Changes to storage objects are not included in DB logical backups. Any recovery plan that includes user-uploaded storage objects requires a separate storage backup.
6. Migration `04_private_order_notes_PREPARED.sql` backfills notes, blanks `orders.note`, installs private-note capture trigger and replaces `get_seller_orders()`. It is **not yet applied to production**. Do not deploy it until backup, staging integration and live schema/trigger compatibility are verified.

## Migration-04 potential side effects
- PostgreSQL `orders_updated_at` BEFORE UPDATE trigger sets `updated_at = now()`. Historical note scrubbing would change `updated_at` for affected orders unless the migration is adjusted to preserve original chronology.
- Potential conflict with existing order triggers (risk/notifications/tenant), access to `private` schema, function ownership, and RLS must be checked.
- `get_seller_orders()` has a deletion side effect for expired, unverified orders; the prepared replacement deliberately preserves that behavior. This is a sensitive operational path requiring testing.
- When successfully migrated, no frontend design change is required; seller's note would remain blank until unlocked.

## Pre-deployment hold point
Backup verified: **NO**
Migration 04 tested against real production schema clone: **NO** (only a dummy GitHub PostgreSQL fixture has passed)
Safe to run production migration 04: **NO**

Reference: https://supabase.com/docs/guides/platform/backups
