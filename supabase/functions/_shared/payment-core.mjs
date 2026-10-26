// Prepared server core. No real provider adapter is shipped or enabled.
// Adapters MUST implement official signatures/status APIs, amount conversion and
// idempotent session creation. Fake adapters belong exclusively in tests.
export function requireProvider(provider) {
  if (!provider || provider.mode !== 'sandbox' || provider.officialVerification !== true ||
      provider.supportsIdempotency !== true || !provider.name || !provider.merchantId ||
      !Array.isArray(provider.checkoutHosts) || !provider.checkoutHosts.length ||
      !['createSession', 'verifyWebhook', 'getTransaction'].every(k => typeof provider[k] === 'function')) {
    throw Error('payment_provider_not_configured');
  }
  return provider;
}
function requireURL(raw, provider) {
  const u = new URL(raw);
  if (u.protocol !== 'https:' || u.username || u.password ||
      !provider.checkoutHosts.includes(u.hostname) || (u.port && u.port !== '443')) {
    throw Error('invalid_provider_checkout_url');
  }
  return u.href;
}
export async function checkout({db, provider, orderId, sellerId}) {
  requireProvider(provider); // fail closed BEFORE creating even a pending DB row
  const payment = await db.prepare(orderId, sellerId, provider.name, provider.merchantId);
  if (payment.unlocked === true) return {unlocked: true};
  if (payment.status !== 'pending') throw Error('payment_terminal_requires_reconciliation');
  if (payment.provider_session_id && payment.checkout_url) {
    return {provider_configured: true, payment_id: payment.id,
      checkout_url: requireURL(payment.checkout_url, provider)};
  }
  // If response is lost, retry the SAME key; do not fail/cancel the attempt on timeout.
  const session = await provider.createSession({idempotencyKey: payment.id,
    paymentId: payment.id, orderId, amountMinor: 500, currency: 'MAD', merchantId: provider.merchantId});
  if (!session?.id) throw Error('invalid_provider_session');
  const url = requireURL(session.url, provider);
  const saved = await db.saveSession(payment.id, session.id, url);
  return {provider_configured: true, payment_id: saved.id, checkout_url: saved.checkout_url};
}
export async function webhook({db, provider, raw, headers}) {
  requireProvider(provider);
  // Adapter verifies official signature over untouched raw bytes, timestamp, merchant,
  // and maps only documented event types. Never use a ShopLink-invented shared HMAC.
  const event = await provider.verifyWebhook(raw, headers);
  if (!event?.eventId || !event.transactionId) throw Error('invalid_provider_event');
  // Always reconcile with official server-to-server status, including retries.
  const tx = await provider.getTransaction(event.transactionId);
  if (!tx || tx.transactionId !== event.transactionId || tx.merchantId !== provider.merchantId ||
      tx.amountMinor !== 500 || tx.currency !== 'MAD' || !tx.paymentId || !tx.orderId || !tx.sessionId ||
      !['succeeded','failed','cancelled','refunded'].includes(tx.status)) {
    throw Error('provider_transaction_invalid');
  }
  return db.applyEvent({provider: provider.name, merchant_id: tx.merchantId,
    event_id: event.eventId, transaction_id: tx.transactionId, payment_id: tx.paymentId,
    order_id: tx.orderId, session_id: tx.sessionId, amount_minor: 500,
    currency: 'MAD', status: tx.status});
}
