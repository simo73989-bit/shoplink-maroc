-- PREPARED ONLY. AFTER verified frontend cutover and client compatibility review.
-- Production main/current open tabs may still use public.place_public_order_v2.
-- Never apply this before placing new place_public_order_idempotent RPC online.
-- Migration must be transactional and tested in PostgreSQL sandbox.
BEGIN;
REVOKE EXECUTE ON FUNCTION public.place_public_order_v2(
  uuid,text,text,text,text,text,text,jsonb
) FROM PUBLIC,anon,authenticated;
-- Retain service_role for controlled internal operations, if present.
GRANT EXECUTE ON FUNCTION public.place_public_order_v2(
  uuid,text,text,text,text,text,text,jsonb
) TO service_role;
-- New idempotent wrapper is SECURITY DEFINER and should still be able to
-- call the v2 function under its privileged database owner.
COMMIT;

-- Verify after application:
-- SELECT has_function_privilege('anon','public.place_public_order_v2(uuid,text,text,text,text,text,text,jsonb)','EXECUTE'); -- false
-- SELECT has_function_privilege('authenticated','public.place_public_order_v2(uuid,text,text,text,text,text,text,jsonb)','EXECUTE'); -- false
-- SELECT has_function_privilege('anon','public.place_public_order_idempotent(uuid,uuid,text,text,text,text,text,text,jsonb)','EXECUTE'); -- true
-- IMPORTANT: Open clients that still use v2 will stop creating orders.
-- Coordinate an application cache/version policy; never deploy by itself.
