'use strict';
const assert=require('node:assert/strict');
exports.run=async function(html){
  const exportCode=html.slice(html.indexOf('function slxExportOrders(){'),html.indexOf('\n}',html.indexOf('function slxExportOrders(){'))+2);
  let captured;
  const order={customer_name:'=HYPERLINK("https://evil.invalid")',phone:'0600000000',address:'Private street',
    total:5,status:'new',items:[{qty:1,name:'Item'}],contact_unlocked:false};
  const run=new Function('state','toast','formatDate','statusLabels','Blob','URL','document','setTimeout',
    exportCode+';slxExportOrders();');
  run({orders:[order]},()=>{},()=> '2026-01-01',{new:'Nouveau'},class{constructor(parts){captured=parts.join('')}},
    {createObjectURL:()=> 'blob:test',revokeObjectURL(){}},{createElement:()=>({click(){}})},()=>{});
  assert.ok(!captured.includes(order.phone));assert.ok(!captured.includes(order.address));
  assert.ok(captured.includes("'=HYPERLINK"),'CSV formula prefix neutralized');
  const start=html.indexOf('  const sl65UnlockInFlight=');
  const end=html.indexOf('\n\n  const SL41_publicStore',start);
  assert.ok(start>0&&end>start);
  let calls=0,resolve;const opened=[];
  const factory=new Function('window','api','state','toast','friendlyError','sl41PaymentModal','sl41RefreshOrders',
    'sl41OpenPayment','URL',html.slice(start,end)+';return window.sl41UnlockContact;');
  const fakeWindow={open:u=>opened.push(u)};
  const unlock=factory(fakeWindow,()=>{calls++;return new Promise(r=>{resolve=r})},{orders:[]},()=>{},e=>e.message,()=>{},async()=>{},()=>{},URL);
  const a=unlock('order-1'),b=unlock('order-1');assert.equal(calls,1);
  resolve({provider_configured:false});await Promise.all([a,b]);
  const openCode=html.slice(html.indexOf('  window.sl41OpenPayment=function('),html.indexOf('\n  window.sl41VerifyUnlock'));
  new Function('window','toast','URL',openCode)(fakeWindow,()=>{},URL);
  fakeWindow.sl41OpenPayment('o','p','https://sandbox.example/pay?token=server');
  assert.equal(opened[0],'https://sandbox.example/pay?token=server','browser does not rewrite amount/reference');
  for(const raw of ['javascript:alert(1)','http://sandbox.example','https://user:pass@sandbox.example'])fakeWindow.sl41OpenPayment('o','p',raw);
  assert.equal(opened.length,1);
  console.log('PASS: seller CSV masking/formula safety, payment double click and immutable HTTPS checkout URL');
};
