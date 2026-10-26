// No fetch/network permission: proves prepared defaults cannot contact Auth/DB/PSP.
import {handler as checkout} from '../supabase/functions/contact-unlock/index.ts';
import {handler as webhook} from '../supabase/functions/contact-payment-webhook/index.ts';
import {limitedBody} from '../supabase/functions/_shared/payment-runtime.ts';
function assert(ok: unknown) { if(!ok)throw Error('assertion_failed'); }
Deno.test('unconfigured endpoints fail closed without network access',async()=>{
  for(const handler of [checkout,webhook]){
    const r=await handler(new Request('https://test.invalid',{method:'POST',body:'{}'}));
    assert(r.status===503);assert(!(await r.json()).ok);
    assert((await handler(new Request('https://test.invalid'))).status===405);
  }
});
Deno.test('only configured browser origin gets CORS headers',async()=>{
  Deno.env.set('CONTACT_PAYMENT_ALLOWED_ORIGIN','https://sandbox.example');
  try{
    const good=await checkout(new Request('https://test.invalid',{method:'OPTIONS',headers:{Origin:'https://sandbox.example'}}));
    assert(good.status===204);assert(good.headers.get('Access-Control-Allow-Origin')==='https://sandbox.example');
    const bad=await checkout(new Request('https://test.invalid',{method:'POST',headers:{Origin:'https://evil.invalid'},body:'{}'}));
    assert(bad.status===403);assert(!bad.headers.has('Access-Control-Allow-Origin'));
  }finally{Deno.env.delete('CONTACT_PAYMENT_ALLOWED_ORIGIN');}
});
Deno.test('body reader preserves exact signed bytes and rejects oversized input',async()=>{
  const raw='{"amount":5, "spaces":"  "}\n';
  assert(new TextDecoder().decode(await limitedBody(new Request('https://test.invalid',{method:'POST',body:raw}),100))===raw);
  let failed=false;
  try{await limitedBody(new Request('https://test.invalid',{method:'POST',body:'x'.repeat(20)}),10);}catch{failed=true;}
  assert(failed);
});
