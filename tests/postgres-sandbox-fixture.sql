-- Ephemeral PostgreSQL 17 harness. NO production Supabase access or real customer data.
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN;
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
CREATE SCHEMA extensions;
CREATE EXTENSION pgcrypto WITH SCHEMA extensions;

CREATE TABLE public.orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  payload jsonb NOT NULL
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
