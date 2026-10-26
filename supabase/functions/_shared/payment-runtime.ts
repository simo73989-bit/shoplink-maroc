// Prepared replacements, NOT deployed. Uses native fetch; no third-party SDK.
export function serviceDatabase() {
  const url = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) throw Error('service_configuration_missing');
  async function rpc(name: string, body: object) {
    const r = await fetch(url + '/rest/v1/rpc/' + name, {method: 'POST',
      headers: {apikey: key!, Authorization: 'Bearer ' + key, 'Content-Type': 'application/json'},
      body: JSON.stringify(body)});
    if (!r.ok) throw Error('payment_database_rejected');
    return r.json();
  }
  return {
    prepare: (order: string, seller: string, provider: string, merchant: string) =>
      rpc('prepare_contact_payment', {p_order_id: order, p_seller_id: seller,
        p_provider: provider, p_merchant_id: merchant}),
    saveSession: (payment: string, session: string, url: string) =>
      rpc('save_contact_payment_session', {p_payment_id: payment,p_session_id: session,p_checkout_url: url}),
    applyEvent: (event: object) => rpc('apply_contact_payment_event', {p_event: event})
  };
}
export async function sellerIdentity(req: Request) {
  const url = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_ANON_KEY');
  const authorization = req.headers.get('authorization');
  if (!url || !key || !authorization?.startsWith('Bearer ')) throw Error('unauthorized');
  const response = await fetch(url + '/auth/v1/user', {headers: {apikey: key, Authorization: authorization}});
  if (!response.ok) throw Error('unauthorized');
  const user = await response.json();
  if (!user.id) throw Error('unauthorized');
  return user.id;
}
export function reply(body: object, status = 200, extraHeaders: Record<string,string> = {}) {
  return new Response(JSON.stringify(body), {status,
    headers: {'Content-Type': 'application/json', 'Cache-Control': 'no-store', ...extraHeaders}});
}
export function browserHeaders(req: Request): Record<string,string> {
  const origin = req.headers.get('origin');
  const allowed = Deno.env.get('CONTACT_PAYMENT_ALLOWED_ORIGIN');
  if (origin && (!allowed || origin !== allowed)) throw Error('origin_not_allowed');
  return origin ? {'Access-Control-Allow-Origin': origin, 'Vary': 'Origin',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info'} : {};
}
export async function limitedBody(req: Request, limit: number) {
  const reader = req.body?.getReader();
  if (!reader) return new Uint8Array();
  const chunks: Uint8Array[] = []; let size=0;
  try {
    while (true) {
      const {done,value} = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > limit) { await reader.cancel(); throw Error('payload_too_large'); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(size); let offset=0;
  for (const chunk of chunks) {bytes.set(chunk,offset);offset+=chunk.byteLength;}
  return bytes;
}
