'use strict';
// GATEWAY-AGNOSTIC SANDBOX SPECIFICATION; never use as a real payment processor.
// Simulates merchant/provider checkout idempotency, signature verification,
// provider amount verification, duplicate events and unlock-once DB policy.
// DOES NOT execute external payments or access Supabase credentials.
const assert=require('node:assert/strict');
const {createHmac,timingSafeEqual}=require('node:crypto');

const MAD=5;
const SECRET='TEST_ONLY_NOT_A_REAL_GATEWAY_SECRET';
const signing=(body)=>createHmac('sha256',SECRET).update(body).digest('hex');
function requireSignedEvent(raw,signature){
  const expected=Buffer.from(signing(raw),'hex');
  if(typeof signature!=='string'||!/^[0-9a-f]{64}$/i.test(signature))throw Error('unsigned_event');
  const supplied=Buffer.from(signature,'hex');
  if(!timingSafeEqual(expected,supplied))throw Error('bad_provider_signature');
  const event=JSON.parse(raw);
  if(event.currency!=='MAD'||event.amount!==MAD)throw Error('amount_currency_invalid');
  if(!event.id||!event.provider_payment_id||!event.payment_id||!event.order_id)throw Error('missing_event_identity');
  return event;
}
class CheckoutHarness{
  constructor(){this.orders=new Map();this.pending=new Map();this.attempts=new Map();this.events=new Set();this.charges=0;this.unlocks=0;}
  addOrder(id,seller){this.orders.set(id,{seller,verified:true,unlocked:false,paymentId:null})}
  // Represents an atomic database row lock + transaction and PSP API idempotency by payment UUID.
  async checkout(orderId,caller){
    const order=this.orders.get(orderId);
    if(!order||caller!==order.seller)throw Error('unauthorized');
    if(!order.verified)throw Error('otp_not_verified');
    if(order.unlocked)return {unlocked:true};
    // A real implementation must do this part with a DB row lock/unique constraint.
    if(!order.paymentId)order.paymentId='payment:'+orderId;
    const paymentId=order.paymentId;
    const prior=this.attempts.get(paymentId);
    if(prior)return prior;
    if(this.pending.has(paymentId))return this.pending.get(paymentId);
    const job=(async()=>{
      await new Promise(resolve=>setImmediate(resolve));
      // PSP also must honor this idempotency key, not the browser's order ID or amount.
      this.charges++;
      const session={payment_id:paymentId,order_id:orderId,amount:MAD,currency:'MAD',
        provider_session_id:'sandbox-session:'+paymentId,idempotency_key:paymentId};
      this.attempts.set(paymentId,session);
      return session;
    })();
    this.pending.set(paymentId,job);
    try{return await job}finally{this.pending.delete(paymentId)}
  }
  webhook(raw,signature){
    const e=requireSignedEvent(raw,signature);
    if(this.events.has(e.id))return {duplicate_event:true,unlocks:this.unlocks};
    const session=this.attempts.get(e.payment_id);
    if(!session||session.order_id!==e.order_id)throw Error('payment_order_mismatch');
    const order=this.orders.get(e.order_id);
    if(!order||order.paymentId!==e.payment_id)throw Error('payment_not_found');
    // Real implementation must verify provider transaction status from PSP API and/or
    // provider-native signed callbacks. A SHOPLINK-owned shared HMAC alone is insufficient.
    if(e.status==='succeeded'){
      if(!order.unlocked){order.unlocked=true;order.providerPaymentId=e.provider_payment_id;this.unlocks++}
      else if(order.providerPaymentId!==e.provider_payment_id)throw Error('additional_external_charge_requires_reconciliation');
    }
    this.events.add(e.id);
    return {ok:true,unlocks:this.unlocks};
  }
}
async function run(){
  const pay=new CheckoutHarness();
  pay.addOrder('ord-1','owner-A');
  const sessions=await Promise.all(Array.from({length:15},()=>pay.checkout('ord-1','owner-A')));
  assert.equal(new Set(sessions.map(x=>x.provider_session_id)).size,1);
  assert.equal(pay.charges,1,'concurrent click/retry must initiate provider session once');
  assert.equal(sessions[0].amount,5);
  assert.equal(sessions[0].currency,'MAD');
  await assert.rejects(()=>pay.checkout('ord-1','other-seller'),/unauthorized/);
  const good={id:'evt-1',payment_id:sessions[0].payment_id,order_id:'ord-1',
    provider_payment_id:'psp-charge-1',status:'succeeded',amount:5,currency:'MAD'};
  const raw=JSON.stringify(good);
  assert.throws(()=>pay.webhook(raw,'00'.repeat(32)),/bad_provider_signature/);
  assert.throws(()=>pay.webhook(JSON.stringify({...good,amount:1}),signing(JSON.stringify({...good,amount:1}))),/amount_currency_invalid/);
  assert.throws(()=>pay.webhook(JSON.stringify({...good,order_id:'ord-2'}),signing(JSON.stringify({...good,order_id:'ord-2'}))),/payment_order_mismatch/);
  assert.equal(pay.webhook(raw,signing(raw)).ok,true);
  assert.equal(pay.webhook(raw,signing(raw)).duplicate_event,true);
  assert.equal(pay.unlocks,1,'duplicate webhook should never unlock again');
  const replayAnotherEvent=JSON.stringify({...good,id:'evt-2'});
  assert.equal(pay.webhook(replayAnotherEvent,signing(replayAnotherEvent)).ok,true);
  assert.equal(pay.unlocks,1);
  const newCharge=JSON.stringify({...good,id:'evt-3',provider_payment_id:'psp-charge-2'});
  assert.throws(()=>pay.webhook(newCharge,signing(newCharge)),/additional_external_charge_requires_reconciliation/);
  assert.deepEqual(await pay.checkout('ord-1','owner-A'),{unlocked:true});
  assert.equal(pay.charges,1);
  console.log('PASS: payment checkout contract sandbox (concurrent retry x15, one session, 5 MAD, owner auth, signed callback, duplicate events, suspicious second charge)');
}
run().catch(e=>{console.error(e);process.exitCode=1});
