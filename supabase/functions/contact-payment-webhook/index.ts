// PREPARED ONLY. Deploy only after official adapter and isolated integration approval.
import {webhook, requireProvider} from '../_shared/payment-core.mjs';
import {configuredProvider} from '../_shared/provider.mjs';
import {reply, serviceDatabase, limitedBody} from '../_shared/payment-runtime.ts';
export async function handler(req: Request) {
  if (req.method !== 'POST') return reply({error: 'method_not_allowed'}, 405);
  try {
    const provider = requireProvider(configuredProvider());
    const raw = await limitedBody(req,65536);
    return reply(await webhook({db: serviceDatabase(),provider,raw,headers: req.headers}));
  } catch {
    // Non-2xx keeps retries possible; no success acknowledged before DB commit.
    return reply({error: 'payment_event_not_accepted'}, 503);
  }
}
if (import.meta.main) Deno.serve(handler);
