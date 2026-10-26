// PREPARED ONLY. No legacy URL fallback. Provider is deliberately unconfigured.
import {checkout, requireProvider} from '../_shared/payment-core.mjs';
import {configuredProvider} from '../_shared/provider.mjs';
import {reply, sellerIdentity, serviceDatabase, browserHeaders, limitedBody} from '../_shared/payment-runtime.ts';
export async function handler(req: Request) {
  let cors: Record<string,string>;
  try {cors=browserHeaders(req);} catch {return reply({error:'origin_not_allowed'},403);}
  if (req.method === 'OPTIONS') return new Response(null,{status:204,headers:cors});
  if (req.method !== 'POST') return reply({error: 'method_not_allowed'}, 405,cors);
  try {
    const provider = requireProvider(configuredProvider());
    const sellerId = await sellerIdentity(req);
    const body = JSON.parse(new TextDecoder().decode(await limitedBody(req,4096)));
    if (typeof body.order_id !== 'string') return reply({error: 'invalid_order'}, 400,cors);
    return reply(await checkout({db: serviceDatabase(),provider,orderId: body.order_id,sellerId}),200,cors);
  } catch {
    // Do not expose DB errors, JWTs, contact data or provider responses.
    return reply({provider_configured: false,error: 'payment_unavailable'}, 503,cors);
  }
}
if (import.meta.main) Deno.serve(handler);
