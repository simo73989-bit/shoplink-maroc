-- SECURITY RELEASE STEP, PREPARED ONLY. DO NOT APPLY BEFORE THE FIXED FRONTEND IS LIVE.
-- The production main frontend still attempts verify_order_phone_test_guest.
-- Applying this on its own would break that legacy checkout path.
-- Run only after deploying a reviewed frontend that uses real SMS OTP,
-- plus regression testing in staging and production backup/rollback plan.
REVOKE EXECUTE ON FUNCTION public.verify_order_phone_test_guest(uuid,text,text)
  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.verify_order_phone_test(uuid,text)
  FROM PUBLIC, anon, authenticated;
-- Deliberately preserve EXECUTE for service_role for any controlled internal recovery work.
-- Later, drop these RPCs only after checking all external clients and scheduled jobs.
-- Verification checks:
-- select has_function_privilege('anon','public.verify_order_phone_test_guest(uuid,text,text)','EXECUTE');  -- false
-- select has_function_privilege('authenticated','public.verify_order_phone_test_guest(uuid,text,text)','EXECUTE'); -- false
-- select has_function_privilege('authenticated','public.verify_order_phone_test(uuid,text)','EXECUTE'); -- false
-- Verify production verify_order_phone(uuid) remains accessible to authenticated users.
