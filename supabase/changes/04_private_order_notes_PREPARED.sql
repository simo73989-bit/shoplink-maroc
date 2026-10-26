-- PREPARED ONLY — NOT APPLIED TO SHOPLINK MAROC PRODUCTION.
-- Goal: lock free-text customer note behind the same paid contact unlock.
-- Read-only inspection confirmed private schema exists and is not usable by anon/authenticated.
-- Required order: staging test, backup, then independent supervised production migration.
-- Migration atomically backfills historical notes, scrubs orders.note, and installs
-- the AFTER write guard. No frontend layout changes. Requires table ownership.
BEGIN;

CREATE TABLE private.order_notes (
  order_id uuid PRIMARY KEY REFERENCES public.orders(id) ON DELETE CASCADE,
  note text NOT NULL DEFAULT ''
);
REVOKE ALL ON TABLE private.order_notes FROM PUBLIC, anon, authenticated;
ALTER TABLE private.order_notes ENABLE ROW LEVEL SECURITY;

-- Preserve preexisting notes BEFORE removing them from the seller-readable orders table.
INSERT INTO private.order_notes(order_id, note)
SELECT id, note FROM public.orders WHERE note <> '';

-- This touches updated_at on existing orders if an updated_at trigger is present.
UPDATE public.orders SET note = '' WHERE note <> '';

-- AFTER (not BEFORE) permits the new orders row to exist for FK integrity.
CREATE FUNCTION private.capture_order_note() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO pg_catalog, pg_temp
AS $fn$
BEGIN
  -- Our own UPDATE to scrub orders.note fires this trigger again at depth 2.
  IF pg_trigger_depth() > 1 THEN RETURN NULL; END IF;

  IF coalesce(NEW.note, '') = '' THEN
    DELETE FROM private.order_notes WHERE order_id = NEW.id;
  ELSE
    INSERT INTO private.order_notes(order_id,note) VALUES (NEW.id,NEW.note)
    ON CONFLICT (order_id) DO UPDATE SET note = EXCLUDED.note;
    UPDATE public.orders SET note = '' WHERE id = NEW.id;
  END IF;
  RETURN NULL;
END;
$fn$;
REVOKE ALL ON FUNCTION private.capture_order_note()
  FROM PUBLIC, anon, authenticated;
CREATE TRIGGER trg_private_order_note
AFTER INSERT OR UPDATE OF note ON public.orders
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
  DELETE FROM public.orders o
  USING public.shops s
  WHERE o.shop_id=s.id
    AND s.owner_id=auth.uid()
    AND o.seller_id=auth.uid()
    AND o.phone_verified IS NOT TRUE
    AND o.verification_expires_at IS NOT NULL
    AND o.verification_expires_at <= now();

  RETURN QUERY
  SELECT
    o.id,
    upper(substr(replace(o.id::text,'-',''),1,8)),
    o.shop_id,
    o.customer_name,
    CASE WHEN o.contact_unlocked THEN c.phone ELSE o.phone END,
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
  ORDER BY o.created_at DESC;
END;
$fn$;

COMMIT;

-- POST-DEPLOY READ-ONLY CHECKS (for verified staging, not run here):
-- SELECT COUNT(*) FROM public.orders WHERE note <> ''; -- must be zero
-- SELECT relrowsecurity FROM pg_class WHERE oid='private.order_notes'::regclass; -- true
-- SELECT has_table_privilege('authenticated','private.order_notes','SELECT'); -- false
-- SELECT has_schema_privilege('authenticated','private','USAGE'); -- false
-- Exercise: before/after paid unlock, seller A vs B, direct orders SELECT,
-- INSERT note, UPDATE note, clear note, delete order, rollback, and RLS.
-- RISK: historical orders.updated_at values may change when scrubbing notes;
-- inspect whether the app relies on that chronology before production rollout.
-- ROLLBACK: never restore sensitive notes into public.orders.note.
