-- Ephemeral PostgreSQL 17 harness. NO production Supabase access or real customer data.
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN;
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
CREATE SCHEMA extensions;
CREATE EXTENSION pgcrypto WITH SCHEMA extensions;

CREATE SCHEMA private;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE
AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;

CREATE TABLE public.shops (
  id uuid PRIMARY KEY,
  owner_id uuid NOT NULL
);
CREATE TABLE public.orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  payload jsonb NOT NULL,
  shop_id uuid REFERENCES public.shops(id),
  seller_id uuid,
  customer_name text NOT NULL DEFAULT '',
  phone text NOT NULL DEFAULT '',
  city text NOT NULL DEFAULT '',
  address text NOT NULL DEFAULT '',
  delivery_method text NOT NULL DEFAULT '',
  note text NOT NULL DEFAULT '',
  items jsonb NOT NULL DEFAULT '[]'::jsonb,
  total numeric NOT NULL DEFAULT 0,
  status text NOT NULL DEFAULT 'new',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  contact_unlocked boolean NOT NULL DEFAULT false,
  unlock_price numeric NOT NULL DEFAULT 5,
  unlocked_at timestamptz,
  payment_status text NOT NULL DEFAULT 'locked',
  payment_id uuid,
  phone_verified boolean NOT NULL DEFAULT false,
  verification_expires_at timestamptz
);
CREATE TABLE public.order_contacts (
  order_id uuid PRIMARY KEY REFERENCES public.orders(id) ON DELETE CASCADE,
  phone text NOT NULL,
  address text NOT NULL DEFAULT ''
);

-- Controlled stub models the call boundary, not the production implementation.
-- The real place_public_order_v2 is separately reviewed through read-only Supabase.
CREATE FUNCTION public.place_public_order_v2(
  p_shop_id uuid,
  p_customer_name text,
  p_phone text,
  p_city text,
  p_address text,
  p_delivery_method text,
  p_note text,
  p_items jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,pg_temp
AS $$
DECLARE v_id uuid := gen_random_uuid();
BEGIN
  -- Delay makes two simultaneous attempts overlap consistently.
  PERFORM pg_sleep(0.3);
  INSERT INTO public.orders(id,payload)
  VALUES (v_id,jsonb_build_array(p_shop_id,p_customer_name,p_phone,p_city,p_address,p_delivery_method,p_note,p_items));
  RETURN jsonb_build_object(
    'id',v_id,
    'order_number',upper(substr(replace(v_id::text,'-',''),1,8)),
    'total',5.0,
    'created_at',now(),
    'phone_verified',false,
    'verification_expires_at',now()+interval '30 minutes',
    'reused_pending',false
  );
END;
$$;


-- Dummy OTP RPCs to test permission revocation ONLY. These never send SMS.
CREATE FUNCTION public.verify_order_phone_test_guest(p_order_id uuid,p_phone text,p_code text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog
AS $$ SELECT jsonb_build_object('ok',false) $$;
CREATE FUNCTION public.verify_order_phone_test(p_order_id uuid,p_code text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog
AS $$ SELECT jsonb_build_object('ok',false) $$;
CREATE FUNCTION public.verify_order_phone(p_order_id uuid)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog
AS $$ SELECT jsonb_build_object('ok',true,'phone_verified',true) $$;
REVOKE EXECUTE ON FUNCTION public.verify_order_phone(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.verify_order_phone(uuid) TO authenticated;
