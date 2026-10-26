-- PREPARED ONLY: AFTER compatible SMS-only frontend release and backup.
-- NEVER deploy alone while main still calls guest test OTP.
-- Confirm no legitimate integrations need these insecure test RPCs.
BEGIN;
REVOKE EXECUTE ON FUNCTION public.verify_order_phone_test_guest(uuid,text,text)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.verify_order_phone_test(uuid,text)
  FROM PUBLIC, anon, authenticated, service_role;
-- Do not grant service_role access unless a documented internal recovery service needs it.
-- Real verified SMS RPC public.verify_order_phone(uuid) is NOT changed.
COMMIT;

-- Post-deploy verify (read-only):
-- select has_function_privilege('anon','public.verify_order_phone_test_guest(uuid,text,text)','EXECUTE'); -- false
-- select has_function_privilege('authenticated','public.verify_order_phone_test_guest(uuid,text,text)','EXECUTE'); -- false
-- select has_function_privilege('authenticated','public.verify_order_phone_test(uuid,text)','EXECUTE'); -- false
-- select has_function_privilege('authenticated','public.verify_order_phone(uuid)','EXECUTE'); -- true
-- Also enumerate overloaded RPCs, wrappers and function-level ACLs.
