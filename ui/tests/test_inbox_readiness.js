const assert = require("assert");
const {load} = require("./load");
const readiness = load("inbox/Readiness.js");
const ready = {version:2,state:"ready",text:"Verified description",expiresAt:2000};
assert(readiness.ready(ready,1000));
assert(!readiness.ready(ready,2000));
for (const change of [{version:1},{state:"running"},{state:"failed"},{text:""},{text:" "},{text:"<img>"},{text:"private\ntext"},{text:"x".repeat(141)},{expiresAt:-1},{expiresAt:"0"},{expiresAt:Infinity}]) assert(!readiness.ready({...ready,...change},1000));
assert(readiness.ready({...ready,expiresAt:0},99999999));
console.log("Inbox readiness checks passed");
