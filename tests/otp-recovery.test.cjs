'use strict';
const assert=require('node:assert/strict');
exports.run=async function(html){
  const code=html.slice(html.indexOf('  window.sl54VerifyOtp=async function(){'),html.indexOf('  // One durable record spans RPC uncertainty'));
  assert.ok(code.includes('verify_order_phone'));
  for(const kind of ['tracking','retry','false','auth-lost','business-false','http-fail']){
    let auth=0,rpc=0,success=0;
    const s={orderId:'order-1',phone:'0612345670',ref:'TEST',name:'Test'};
    const element=()=>({dataset:{},append(){},appendChild(){},remove(){}});
    const document={querySelector:q=>q==='#sl54OtpCode'?{value:'123456'}:null,createElement:element,
      createTextNode:x=>x,body:{appendChild(x){if(x.dataset.otpSuccess)success++}}};
    const fetch=async url=>{
      if(url.includes('/auth/v1/verify')){auth++;if(kind==='auth-lost')throw Error('lost auth response');return {ok:true,json:async()=>({access_token:'TEST_ONLY'})};}
      if(url.includes('/logout'))return {ok:true};
      rpc++;
      if(kind==='retry'&&rpc>1)return {ok:true,json:async()=>({ok:true,phone_verified:true})};
      if(kind==='false')return {ok:true,json:async()=>({ok:true,phone_verified:false})};
      if(kind==='business-false')return {ok:true,json:async()=>({ok:false,phone_verified:true})};
      if(kind==='http-fail')return {ok:false,json:async()=>({ok:true,phone_verified:true})};
      throw Error('confirmation response lost');
    };
    const factory=new Function('window','document','fetch','api','toast','setBusy','friendlyError','sessionStorage',
      'SUPABASE_URL','SUPABASE_KEY','sl54PhoneE164','sl54RejectExpired','sl65ClearCreatedAttempt','sl54CooldownKey',
      `let sl54OtpState=${JSON.stringify(s)},sl65OtpGrant=null,sl54ResendTimer=null;const sl54VerifyingKeys=new Set();const sl54SendKey=s=>s.orderId;${code};return window.sl54VerifyOtp;`);
    const run=factory({},document,fetch,async()=>({phone_verified:kind==='tracking'}),()=>{},()=>{},e=>e.message,
      {getItem:()=>null,removeItem(){}},'https://mock.invalid','TEST_ONLY',x=>x,()=>false,()=>{},()=> 'cooldown');
    await run();if(kind==='retry')await run();
    assert.equal(auth,1,kind+': no extra SMS Auth consumption');
    assert.equal(success,kind==='tracking'||kind==='retry'?1:0,kind+': authoritative success only');
    if(kind==='auth-lost')assert.equal(rpc,0);
  }
  console.log('PASS: 6 OTP recovery mocks (no real SMS), including no false success');
};
