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

const details = load("inbox/PointDetails.js");
assert.deepStrictEqual(Array.from(details.rows({state:"stale",tier:"haiku"}), row=>row.title).slice(0,2), ["Requested model","Created with"]);
assert.deepStrictEqual(Array.from(details.rows({state:"stale",tier:"haiku"}), row=>row.value).slice(0,2), ["Not recorded","Claude Haiku"]);
assert.deepStrictEqual(Array.from(details.rows({state:"ready",tier:"opus"}), row=>row.value), ["Not recorded","Claude Opus","Not recorded","Not recorded","Not recorded","Not recorded","Not recorded","Not recorded"]);
assert.deepStrictEqual(Array.from(details.rows({state:"ready",details:{requestedModel:"claude-sonnet-5-5",model:"claude-haiku-5-5",gmailMs:0,decideMs:42,createMs:2500}}), row=>row.value), ["Claude Sonnet 5.5","Claude Haiku 5.5","0 ms","42 ms","2.5 seconds","Not recorded","Not recorded","Not recorded"]);
for (const value of [null,undefined,-1,0.5,86400001,"125"]) assert.strictEqual(details.duration(value), "");
for (const value of ["__proto__","constructor","<b>Sonnet</b>"]) assert.strictEqual(details.model(value), "");
assert.strictEqual(details.duration(62100),"1 min 2 sec");
assert.strictEqual(details.note({details:{batchSize:3}}),"The writing time is shared by 3 Points written together.");
for (const value of [{...ready,expiresAt:1},{state:"stale"},{state:"running",previousPoint:true},{state:"waiting",previousPoint:true}]) {
  assert.strictEqual(readiness.status(value,1000,false),"plain","rewrites never become waiting cards");
  const queue=readiness.stack([{id:"old"},{id:"new"}], row=>row.id==="old"?value:{},()=>false,1000,true);
  assert.strictEqual(queue.count,1);
  assert.strictEqual(queue.currentId,"new");
  assert.deepStrictEqual(Array.from(queue.messages,row=>row.id),["new","old"]);
}
console.log("Point details and quiet rewrite checks passed");

const arrivals = load("inbox/PointArrivals.js");
const arrivalRows = [{id:"one"},{id:"existing"},{id:"two"},{id:"rewrite"}];
let arrivalValues = {existing:{...ready,expiresAt:0},rewrite:{state:"waiting",previousPoint:true}};
const arrivalValue = row => arrivalValues[row.id];
let arrivalState = arrivals.update(null,arrivalRows,arrivalValue,row=>row.id==="two",1000,true,"account");
assert.deepStrictEqual(Array.from(arrivalState.queued),["two","one"]);
arrivalValues.one = {...ready,expiresAt:0}; arrivalValues.two = {...ready,expiresAt:0};
arrivalState = arrivals.update(arrivalState,arrivalRows,arrivalValue,()=>false,1000,true,"account");
assert.deepStrictEqual(Array.from(arrivalState.queued),["two","one"],"batch completions stay queued until their transition finishes");
assert.deepStrictEqual(Array.from(arrivals.projection(arrivalState,arrivalRows,true).messages,row=>row.id),["two","existing","rewrite"]);
assert.strictEqual(arrivals.finish(arrivalState,"one"),arrivalState,"stale finish cannot remove another current card");
arrivalState=arrivals.finish(arrivalState,"two");
assert.deepStrictEqual(Array.from(arrivals.projection(arrivalState,arrivalRows,true).messages,row=>row.id),["one","two","existing","rewrite"]);
arrivalState=arrivals.finish(arrivalState,"one");
assert.deepStrictEqual(Array.from(arrivals.projection(arrivalState,arrivalRows,true).messages,row=>row.id),["one","two","existing","rewrite"]);
assert.strictEqual(arrivals.projection(arrivalState,arrivalRows,true).count,0);
assert.deepStrictEqual(Array.from(arrivals.update(arrivalState,arrivalRows,arrivalValue,()=>false,1000,true,"other").delivered),[]);
assert.strictEqual(arrivals.projection(arrivalState,arrivalRows,false).messages,arrivalRows);
assert.deepStrictEqual(Array.from(arrivals.update(arrivalState,arrivalRows,arrivalValue,()=>false,1000,false,"account").queued),[]);
let failedState=arrivals.update(null,arrivalRows,()=>({}),()=>false,1000,true,"account");
failedState=arrivals.update(failedState,[arrivalRows[0]],()=>({state:"failed",attempts:1}),()=>false,1000,true,"account");
assert.strictEqual(failedState.queued.length,0,"removed and failed mail cannot remain stacked");
console.log("Point arrival sequencing checks passed");

const backgroundRun = {origin:"backgroundRefresh",startedAt:100,finishedAt:200,startedActive:false,finishedActive:false,leftApp:false};
const appRun = {...backgroundRun,origin:"app",startedActive:true,finishedActive:true};
assert.strictEqual(details.activity(backgroundRun),"Background refresh");
assert.strictEqual(details.activity(appRun),"While using Magpie");
assert.strictEqual(details.activity({...appRun,leftApp:true}),"While using Magpie; app left during this step");
assert.strictEqual(details.activity({...backgroundRun,finishedActive:true}),"Background refresh; app opened during this step");
assert.deepStrictEqual(Array.from(details.rows({details:{downloadRun:backgroundRun,createRun:appRun}}),row=>row.value).slice(-2),["Background refresh","While using Magpie"]);
for (const run of [null,{}, {...appRun,origin:"<b>unknown</b>"}, {...appRun,startedAt:"100"}, {...appRun,leftApp:"true"}]) assert.strictEqual(details.activity(run),"Not recorded");
console.log("Per-email processing context checks passed");

assert.strictEqual(details.activity({...backgroundRun,startedActive:true,finishedActive:true}),"Background refresh; app already open");
assert.strictEqual(details.activity({origin:"desktop",startedAt:100,finishedAt:200,remainingText:true}),"The main machine (remaining text)");

assert.strictEqual(details.tokens({contextTokens:12345}),"12,345");
assert.strictEqual(details.tokens({contextTokens:12345,contextTokensPartial:true}),"At least 12,345");
for (const n of [null,"123",-1,1.5,9007199254740992]) assert.strictEqual(details.tokens({contextTokens:n}),"Not recorded");
assert.ok(details.note({details:{contextTokens:10,batchSize:3}}).includes("token count are shared by 3"));
