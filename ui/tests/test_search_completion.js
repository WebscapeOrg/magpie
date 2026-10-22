const assert = require("assert")
const {load, deepEqual} = require("./load")
const completion = load("search/Completion.js")
const operators = [
  {operator:"from", values:["me"], description:"Sender"},
  {operator:"to", values:["me"], description:"Recipient"},
  {operator:"is", values:["read","unread","starred"], description:"State"},
  {operator:"label", values:[], description:"Label"},
  {operator:"subject", values:[], description:"Subject"}
]
function matches(text, cursor = text.length, labels = []) {
  return completion.suggestions(text,cursor,cursor,cursor,operators,labels)
}
function apply(text, choice) {
  const edit = completion.replacement(text,choice)
  return text.slice(0,edit.start) + edit.value + text.slice(edit.end)
}
assert.strictEqual(matches("invoice").length,0)
assert.strictEqual(matches("fr")[0].value,"from:")
assert.strictEqual(matches("-fr")[0].value,"-from:")
assert.strictEqual(matches("is:un")[0].value,"is:unread")
assert.strictEqual(matches("is:unread").length,0)
assert.strictEqual(apply("is:un",matches("is:un")[0]),"is:unread ")
const middle = "subject:invoice fr is:unread"
assert.strictEqual(apply(middle,matches(middle,18)[0]),"subject:invoice from: is:unread")
assert.strictEqual(matches('subject:"fr om"').length,0)
assert.strictEqual(matches('(fr OR to:me)',3)[0].value,"from:")
assert.strictEqual(apply('(is:un)',matches('(is:un)',6)[0]),'(is:unread)')
const labels = [{name:"Client work"},{name:"Client work"},{name:'A "quoted" label'},{name:"日本語"}]
assert.strictEqual(matches('label:Cl',8,labels)[0].value,'label:"Client work"')
assert.strictEqual(matches('label:"Client w"',15,labels)[0].value,'label:"Client work"')
assert.strictEqual(matches('label:日',7,labels)[0].value,'label:日本語')
assert.strictEqual(matches('label:A',7,labels)[0].value,'label:"A \\"quoted\\" label"')
assert.strictEqual(completion.suggestions("from:x to:y",9,0,9,operators,[]).length,0)
deepEqual(completion.labelValues(labels),['A "quoted" label',"Client work","日本語"])
deepEqual(completion.exampleInsertion("invoice",7,7,"has:attachment"),{start:7,end:7,value:" has:attachment "})
console.log("test_search_completion.js ok")
