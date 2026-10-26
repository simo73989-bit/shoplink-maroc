'use strict';
// Executes shipped payment core with an explicit fake provider and in-memory DB.
// SQL/locks/roles are tested separately on PostgreSQL. NO real PSP integration.
const assert = require('node:assert/strict');
const {test} = require('node:test');
const core = import('../supabase/functions/_shared/payment-core.mjs');
function fixture() {
  const sessions = new Map(); let creates=0, loseResponse=false, unlocks=0;
  const payment={id:'payment-1',status:'pending',order_id:'order-1'};
  const db={
    async prepare(order,seller) {assert.equal(order,'order-1');if(seller!=='seller-A')throw Error('unauthorized');return {...payment};},
    async saveSession(id,session,url) {assert.equal(id,payment.id);payment.provider_session_id=session;payment.checkout_url=url;return {...payment};},
    async applyEvent(e) {unlocks++;return {ok:true,event:e};}
  };
  const tx={transactionId:'tx-1',merchantId:'merchant-test',amountMinor:500,currency:'MAD',
    paymentId:payment.id,orderId:'order-1',sessionId:'session-1',status:'succeeded'};
  const provider={name:'FAKE_TEST_ONLY',mode:'sandbox',officialVerification:true,supportsIdempotency:true,
    merchantId:'merchant-test',checkoutHosts:['sandbox.example'],
    async createSession(args) {
      assert.equal(args.amountMinor,500);assert.equal(args.currency,'MAD');
      assert.equal(args.merchantId,'merchant-test');assert.equal(args.idempotencyKey,payment.id);
      if(!sessions.has(args.idempotencyKey)){creates++;sessions.set(args.idempotencyKey,{id:'session-1',url:'https://sandbox.example/pay/1'});}
      await new Promise(r=>setImmediate(r));
      if(loseResponse){loseResponse=false;throw Error('network_lost');}
      return sessions.get(args.idempotencyKey);
    },
    // A test stub, deliberately NOT an official PSP signature algorithm.
    async verifyWebhook(raw,headers) {if(headers.get('x-test-signature')!=='TEST_ONLY')throw Error('bad_signature');return JSON.parse(new TextDecoder().decode(raw));},
    async getTransaction() {return {...tx};}
  };
  return {db,provider,payment,tx,creates:()=>creates,unlocks:()=>unlocks,lose:()=>{loseResponse=true}};
}
const request=t=>({db:t.db,provider:t.provider,orderId:'order-1',sellerId:'seller-A'});
const event=t=>({db:t.db,provider:t.provider,raw:new TextEncoder().encode(JSON.stringify({eventId:'e1',transactionId:'tx-1'})),headers:new Headers({'x-test-signature':'TEST_ONLY'})});
test('15 concurrent requests use stable provider key, fixed 500 MAD minor units and one session',async()=>{
  const {checkout}=await core,t=fixture();const all=await Promise.all(Array.from({length:15},()=>checkout(request(t))));
  assert.equal(t.creates(),1);assert.equal(new Set(all.map(x=>x.checkout_url)).size,1);
  assert.deepEqual(await checkout(request(t)),all[0]);
});
test('lost provider response retries same provider key; no replacement attempt',async()=>{
  const {checkout}=await core,t=fixture();t.lose();await assert.rejects(checkout(request(t)),/network_lost/);
  const result=await checkout(request(t));assert.equal(result.payment_id,'payment-1');assert.equal(t.creates(),1);
});
test('disabled provider, production mode and provider without idempotency fail closed',async()=>{
  const {checkout}=await core,t=fixture();
  for(const provider of [null,{...t.provider,mode:'production'},{...t.provider,supportsIdempotency:false}])
    await assert.rejects(checkout({...request(t),provider}),/not_configured/);
  assert.equal(t.creates(),0);
});
test('wrong seller and terminal attempts cannot initiate checkout',async()=>{
  const {checkout}=await core,t=fixture();await assert.rejects(checkout({...request(t),sellerId:'seller-B'}),/unauthorized/);
  for(const status of ['failed','cancelled','refunded']){t.payment.status=status;await assert.rejects(checkout(request(t)),/terminal/);}
  assert.equal(t.creates(),0);
});
test('only provider allowlisted HTTPS URL is returned; stored URLs also checked',async()=>{
  const {checkout}=await core;
  for(const url of ['http://sandbox.example/pay','https://evil.example/pay','javascript:alert(1)','https://user:pass@sandbox.example/pay']){
    const t=fixture();t.payment.provider_session_id='existing';t.payment.checkout_url=url;
    await assert.rejects(checkout(request(t)));assert.equal(t.creates(),0);
  }
});
test('unsigned callback cannot reach transaction lookup or DB',async()=>{
  const {webhook}=await core,t=fixture();let lookups=0;t.provider.getTransaction=async()=>{lookups++;return t.tx;};
  await assert.rejects(webhook({...event(t),headers:new Headers()}),/bad_signature/);
  assert.equal(lookups,0);assert.equal(t.unlocks(),0);
});
test('signed event still requires exact PSP transaction, merchant, currency, amount and status',async()=>{
  const {webhook}=await core;
  for(const change of [{amountMinor:499},{amountMinor:'500'},{currency:'EUR'},{merchantId:'other'},
    {transactionId:'other'},{status:'authorized'},{sessionId:null},{paymentId:null}]){
    const t=fixture();Object.assign(t.tx,change);await assert.rejects(webhook(event(t)),/transaction_invalid/);
    assert.equal(t.unlocks(),0);
  }
});
test('normalized authoritative success/failure/cancel/refund events reach the atomic DB RPC',async()=>{
  const {webhook}=await core;
  for(const status of ['succeeded','failed','cancelled','refunded']){
    const t=fixture();t.tx.status=status;const result=await webhook(event(t));
    assert.equal(result.event.amount_minor,500);assert.equal(result.event.status,status);assert.equal(result.event.event_id,'e1');
  }
});
