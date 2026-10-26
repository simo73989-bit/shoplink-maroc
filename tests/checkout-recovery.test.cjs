'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

// Run: node tests/checkout-recovery.test.cjs
// Mock-only tests. Not a substitute for Supabase staging / payment sandbox tests.
async function run(html) {
  const begin = html.indexOf('  // One durable record spans RPC uncertainty');
  const end = html.indexOf('  // Reprendre une commande après actualisation',begin);
  assert.ok(begin>=0 && end>begin, 'checkout section found');
  const checkoutCode=html.slice(begin,end);

  function make(options={}){
    const values={cName:'Test client',cPhone:'0612345670',cCity:'Salé',cAddress:'Street',cNote:'',slxMode:'À convenir'};
    const data=new Map(), calls=[],pending=[],messages=[];
    let storageFails=!!options.storageFails,seq=0,renderFails=!!options.renderFails;
    const storage={
      getItem:k=>{if(storageFails)throw Error('storage disabled');return data.get(k)||null},
      setItem:(k,v)=>{if(storageFails)throw Error('storage disabled');data.set(k,v)},
      removeItem:k=>{if(storageFails)throw Error('storage disabled');data.delete(k)}
    };
    const document={querySelector(q){
      if(q==='#modal')return {remove(){}};
      const id=q.slice(1);return id in values?{value:values[id]}:null;
    }};
    const state={publicShop:{id:'shop'},cart:[{id:'p1',name:'item',qty:1,price:99}]};
    const slxSavePublicOrder=(order,id,body)=>{
      calls.push({id,body:JSON.parse(JSON.stringify(body))});
      return new Promise((resolve,reject)=>pending.push({resolve,reject}));
    };
    const fakeWindow={};
    const instantiate=new Function('window','document','sessionStorage','crypto','state',
      'sl41PhoneOk','toast','setBusy','slxSavePublicOrder','friendlyError','ckey',
      'renderCart','sl54GetResendAt','sl54OtpModal','sl54SendOtp','api',
      'let sl54OtpState=null;\n'+checkoutCode+
      '\nreturn {run:()=>window.placeOrder(),getState:()=>sl54OtpState,attempt:()=>sl65ReadAttempt()};');
    const instance=instantiate(fakeWindow,document,storage,
      {randomUUID:()=> '11111111-1111-4111-8111-'+String(++seq).padStart(12,'0')},
      state,()=>true,m=>messages.push(String(m)),()=>{},slxSavePublicOrder,
      e=>e?.message||String(e),()=> 'cart',()=>{if(renderFails)throw Error('render failed')},
      ()=>0,m=>messages.push(String(m)),()=>Promise.resolve(),
      async()=>({phone_verified:false}));
    return {calls,pending,data,messages,instance,state,
      setStorageFails:v=>{storageFails=v},setRenderFails:v=>{renderFails=v}};
  }

  {
    const t=make({storageFails:true});
    await t.instance.run();
    assert.equal(t.calls.length,0,'never send without durable session record');
  }

  {
    const t=make();
    const a=t.instance.run(),b=t.instance.run();
    assert.equal(t.calls.length,1,'parallel submit guarded');
    t.pending[0].reject(new Error('network lost'));
    await Promise.all([a,b]);
    t.state.cart[0].name='changed after network loss';
    t.state.cart[0].price=2000;
    const retry=t.instance.run();
    assert.equal(t.calls.length,2);
    assert.equal(t.calls[0].id,t.calls[1].id,'UUID stable');
    assert.deepEqual(t.calls[0].body,t.calls[1].body,'RPC arguments immutable');
    t.pending[1].resolve({id:'order-1',order_number:'AABBCCDD',verification_expires_at:'2045-01-01'});
    await retry;
    assert.equal(t.instance.attempt()?.phase,'created');
    assert.equal(t.instance.attempt()?.otpState?.orderId,'order-1');
  }

  {
    const t=make({renderFails:true});
    const p=t.instance.run();
    t.pending[0].resolve({id:'order-2',order_number:'11223344',verification_expires_at:'2045-01-01'});
    await p;
    assert.equal(t.instance.attempt()?.phase,'created','persist receipt before rendering');
    assert.ok(t.data.has('sl54_pending_order'),'recoverable OTP state remains');
  }

  {
    const t=make();
    const p=t.instance.run();
    t.pending[0].reject(new Error('offline'));
    await p;
    t.setStorageFails(true);
    await t.instance.run();
    assert.equal(t.calls.length,1,'no uncertain replay when persistence fails');
  }

  {
    const t=make();
    const first=t.instance.run();
    t.pending[0].reject(new Error('offline'));
    await first;
    const raw=JSON.parse(t.data.get('sl54_order_attempt'));
    raw.createdAt=Date.now()-25*60*60*1000;
    t.data.set('sl54_order_attempt',JSON.stringify(raw));
    const marker=t.instance.attempt();
    assert.equal(marker?.phase,'stale','24h past: stale marker must replace private details');
    assert.equal(JSON.parse(t.data.get('sl54_order_attempt')).body,undefined,'PII removed');
    await t.instance.run();
    assert.equal(t.calls.length,1,'stale attempt does not silently create new order');
  }

  const js=[...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script\s*>/gi)]
    .filter(m=>!/application\/ld\+json/i.test(m[1])&&!/\bsrc\s*=/i.test(m[1]));
  for(const script of js)new Function(script[2]);
  assert.equal(js.length,14,'expected 14 executable inline scripts');
  return 'Checkout recovery mocks and 14 JavaScript parse checks passed';
}

module.exports={run};
if(require.main===module){
  run(fs.readFileSync(path.resolve(__dirname,'../index.html'),'utf8'))
    .then(msg=>console.log('PASS:',msg))
    .catch(err=>{console.error(err);process.exitCode=1});
}
