-- PREPARED ONLY — NOT APPLIED TO SHOPLINK MAROC PRODUCTION.
-- Goal: lock free-text customer note behind the same paid contact unlock.
-- Read-only inspection confirmed private schema exists and is not usable by anon/authenticated.
-- Required order: staging test, backup, then independent supervised production migration.
-- Migration atomically backfills historical notes, scrubs orders.note, and installs
-- the BEFORE write guard. No frontend layout changes. Requires table ownership.
BEGIN;

-- Serialize backfill and trigger installation before reading any historical rows.
LOCK TABLE public.orders IN ACCESS EXCLUSIVE MODE;
DO $preflight$
BEGIN
  IF has_schema_privilege('anon','private','USAGE')
     OR has_schema_privilege('authenticated','private','USAGE') THEN
    RAISE EXCEPTION 'private_schema_access_preflight_failed';
  END IF;
END;
$preflight$;

CREATE TABLE private.order_notes (
  order_id uuid PRIMARY KEY REFERENCES public.orders(id) ON DELETE CASCADE
    DEFERRABLE INITIALLY DEFERRED,
  note text NOT NULL DEFAULT ''
);
REVOKE ALL ON TABLE private.order_notes FROM PUBLIC, anon, authenticated;
ALTER TABLE private.order_notes ENABLE ROW LEVEL SECURITY;

-- Preserve preexisting notes BEFORE removing them from the seller-readable orders table.
INSERT INTO private.order_notes(order_id, note)
SELECT id, note FROM public.orders WHERE note <> '';

-- Existing orders_updated_at BEFORE UPDATE trigger changes updated_at to now().
-- Temporarily disable THIS trigger inside the same transaction while scrubbing
-- historical notes; PostgreSQL rolls back the trigger setting if anything fails.
-- ALTER TABLE acquires an exclusive table lock: schedule downtime or a low-traffic
-- maintenance window after a verified backup, even if today's note count is small.
DO $backfill$
DECLARE trigger_state "char";
BEGIN
  SELECT tgenabled INTO trigger_state FROM pg_trigger
  WHERE tgrelid='public.orders'::regclass AND tgname='orders_updated_at' AND NOT tgisinternal;
  IF NOT FOUND THEN RAISE EXCEPTION 'orders_updated_at_trigger_missing'; END IF;
  ALTER TABLE public.orders DISABLE TRIGGER orders_updated_at;
  UPDATE public.orders SET note='' WHERE note<>'';
  CASE trigger_state
    WHEN 'O' THEN ALTER TABLE public.orders ENABLE TRIGGER orders_updated_at;
    WHEN 'A' THEN ALTER TABLE public.orders ENABLE ALWAYS TRIGGER orders_updated_at;
    WHEN 'R' THEN ALTER TABLE public.orders ENABLE REPLICA TRIGGER orders_updated_at;
    WHEN 'D' THEN NULL; -- retain the pre-existing disabled state
    ELSE RAISE EXCEPTION 'unknown_updated_at_trigger_state';
  END CASE;
END;
$backfill$;

-- A deferred FK allows capturing a note BEFORE the new parent row exists.
-- Scrub NEW directly: no recursive UPDATE, no timestamp mutation, no raw note
-- in INSERT/UPDATE RETURNING. Do not skip writes originating in other triggers.
CREATE FUNCTION private.capture_order_note() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO pg_catalog, pg_temp
AS $fn$
BEGIN
  IF TG_OP='INSERT' THEN
    -- A BEFORE trigger runs even for INSERT ... ON CONFLICT DO NOTHING.
    -- Serialize duplicate IDs and reject them before touching the existing note.
    -- The public order RPC uses new UUIDs; callers must not upsert existing orders.
    PERFORM pg_advisory_xact_lock(hashtextextended('private_order_note:'||NEW.id::text,0));
    IF EXISTS(SELECT 1 FROM public.orders WHERE id=NEW.id) THEN
      RAISE EXCEPTION 'order_id_already_exists';
    END IF;
  END IF;
  IF coalesce(NEW.note, '') = '' THEN
    DELETE FROM private.order_notes WHERE order_id = NEW.id;
  ELSE
    INSERT INTO private.order_notes(order_id,note) VALUES (NEW.id,NEW.note)
    ON CONFLICT (order_id) DO UPDATE SET note = EXCLUDED.note;
  END IF;
  NEW.note := '';
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION private.capture_order_note()
  FROM PUBLIC, anon, authenticated;
CREATE TRIGGER trg_private_order_note
BEFORE INSERT OR UPDATE OF note ON public.orders
FOR EACH ROW EXECUTE FUNCTION private.capture_order_note();

-- Preserve EXACT existing get_seller_orders() output columns and type signature.
-- Require both correct seller ownership and contact_unlocked=true to expose private note.
CREATE OR REPLACE FUNCTION public.get_seller_orders()
RETURNS TABLE (
  id uuid, order_number text, shop_id uuid, customer_name text,
  phone text, city text, address text, delivery_method text,
  note text, items jsonb, total numeric, status text,
  created_at timestamptz, updated_at timestamptz,
  contact_unlocked boolean, unlock_price numeric, unlocked_at timestamptz,
  payment_status text, payment_id uuid, phone_verified boolean,
  verification_expires_at timestamptz
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO pg_catalog, pg_temp
AS $fn$
BEGIN
  -- Reading the seller dashboard must not physically delete historic orders.
  -- Expired unverified rows remain stored, but retain the previous visibility rule.
  RETURN QUERY
  SELECT
    o.id,
    upper(substr(replace(o.id::text,'-',''),1,8)),
    o.shop_id,
    o.customer_name,
    CASE WHEN o.contact_unlocked THEN c.phone ELSE '••••••••••'::text END,
    o.city,
    CASE WHEN o.contact_unlocked THEN coalesce(c.address,'') ELSE '' END,
    o.delivery_method,
    CASE WHEN o.contact_unlocked THEN coalesce(pn.note,'') ELSE '' END,
    o.items,
    o.total,
    o.status,
    o.created_at,
    o.updated_at,
    o.contact_unlocked,
    o.unlock_price,
    o.unlocked_at,
    o.payment_status,
    o.payment_id,
    o.phone_verified,
    o.verification_expires_at
  FROM public.orders o
  JOIN public.shops s ON s.id=o.shop_id
  LEFT JOIN public.order_contacts c ON c.order_id=o.id
  LEFT JOIN private.order_notes pn ON pn.order_id=o.id
  WHERE s.owner_id=auth.uid()
    AND o.seller_id=auth.uid()
    AND NOT (o.phone_verified IS NOT TRUE
      AND o.verification_expires_at IS NOT NULL
      AND o.verification_expires_at <= now())
  ORDER BY o.created_at DESC;
END;
$fn$;

-- CREATE OR REPLACE preserves existing ACLs, including potentially public ones.
REVOKE ALL ON FUNCTION public.get_seller_orders() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_seller_orders() TO authenticated;

COMMIT;

-- POST-DEPLOY READ-ONLY CHECKS (for verified staging, not run here):
-- SELECT COUNT(*) FROM public.orders WHERE note <> ''; -- must be zero
-- SELECT relrowsecurity FROM pg_class WHERE oid='private.order_notes'::regclass; -- true
-- SELECT has_table_privilege('authenticated','private.order_notes','SELECT'); -- false
-- SELECT has_schema_privilege('authenticated','private','USAGE'); -- false
-- Exercise: before/after paid unlock, seller A vs B, direct orders SELECT,
-- INSERT note, UPDATE note, clear note, delete order, rollback, and RLS.
-- The existing orders_updated_at trigger is temporarily disabled ONLY while
-- historical notes are scrubbed, preserving original updated_at timestamps.
-- Migration 04 remains blocking DDL; assess acceptable maintenance window.
-- ROLLBACK: never restore sensitive notes into public.orders.note.
