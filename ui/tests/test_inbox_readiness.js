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
console.log("Inbox readiness checks passed");
