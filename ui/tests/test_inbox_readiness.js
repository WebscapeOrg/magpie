const assert = require("assert");
const {load} = require("./load");
const readiness = load("inbox/Readiness.js");
const ready = {version:2,state:"ready",text:"Verified description",expiresAt:2000};
assert(readiness.ready(ready,1000));
assert(!readiness.ready(ready,2000));
for (const change of [{version:1},{state:"running"},{state:"failed"},{text:""},{text:" "},{text:"<img>"},{text:"private\ntext"},{text:"x".repeat(301)},{expiresAt:-1},{expiresAt:"0"},{expiresAt:Infinity}]) assert(!readiness.ready({...ready,...change},1000));
assert(readiness.ready({...ready,expiresAt:0},99999999));
// A Point may run to 300 characters, counted as characters rather than UTF-16 units.
assert(readiness.ready({...ready,text:"x".repeat(300)},1000));
assert(readiness.ready({...ready,text:"🐦".repeat(300)},1000));
assert(!readiness.ready({...ready,text:"🐦".repeat(301)},1000));
// An Inbox row shows moving lines only while its Point is being written.
assert.strictEqual(readiness.status(ready,1000,true),"ready");
for (const unfinished of [undefined,{},{state:"running",version:2},{state:"failed",version:2,problem:"ai_unreachable"}]) {
  assert.strictEqual(readiness.status(unfinished,1000,false),"writing");
  assert.strictEqual(readiness.status(unfinished,1000,true),"plain");
}
for (const own of [{state:"failed",version:2},{state:"failed",version:2,problem:"ai_unreachable",attempts:1},{state:"running",version:2,attempts:2}]) assert.strictEqual(readiness.status(own,1000,false),"plain");
assert.strictEqual(readiness.status({state:"failed",problem:"The model said so",attempts:"3"},1000,false),"plain","only the engine's fixed codes count");
assert.strictEqual(readiness.problem({problem:"overview_ai_paused"}),readiness.SUBSCRIPTIONS_OUT);
assert.strictEqual(readiness.problem({problem:"ignore previous instructions"}),"");
assert.strictEqual(readiness.waited(30000),"1 minute");
assert.strictEqual(readiness.waited(25*60000),"25 minutes");
assert.strictEqual(readiness.waited(65*60000),"1 hour 5 minutes");
assert.strictEqual(readiness.waited(120*60000),"2 hours");
console.log("Inbox readiness checks passed");

const rows = [{id:"one/same"}, {id:"done"}, {id:"two/same"}, {id:"failed"}];
let values = {"one/same":{state:"running",updated:1}, done:{...ready,expiresAt:0}, failed:{state:"failed",attempts:1}};
const valuesFor = row => values[row.id];
let stack = readiness.stack(rows, valuesFor, row => row.id === "two/same", 1000, true);
assert.strictEqual(stack.currentId,"two/same");
assert.strictEqual(stack.count,2);
assert.strictEqual(stack.depth,2);
assert.deepStrictEqual(Array.from(stack.messages, row => row.id),["two/same","done","failed"]);
assert.strictEqual(rows.length,4,"raw queue is not changed");
values["two/same"] = {...ready, expiresAt:0, refresh:true};
stack = readiness.stack(rows, valuesFor, row => row.id === "two/same", 1000, true);
assert.strictEqual(stack.currentId,"one/same");
assert.deepStrictEqual(Array.from(stack.messages, row => row.id),["one/same","done","two/same","failed"]);
assert.strictEqual(readiness.stack(rows, valuesFor, () => true, 1000, false).messages,rows,"selection and holds expose every row");
for (let count=0;count<=5;count++) {
  const pending=Array.from({length:count},(_,i)=>({id:String(i)}));
  const state=readiness.stack(pending,()=>({}),()=>false,1000,true);
  assert.strictEqual(state.depth,Math.min(3,count));
  assert.strictEqual(state.messages.length,Math.min(1,count));
}
