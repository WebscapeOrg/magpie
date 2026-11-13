const assert = require('assert')
const { load } = require('./load')
const options = load('agent/Options.js')
const copy = value => JSON.parse(JSON.stringify(value))
const payload = {messageId:'synthetic',prompt:'Question'}
assert.deepEqual(copy(options.startOptions(payload,'System default','',5)), {params:{payload}})
for (const [label,provider] of [['OpenCode','opencode'],['Codex','codex'],['Claude','claude']]) {
  assert.deepEqual(copy(options.startOptions(payload,label,'test/model#variant',6)), {params:{payload,provider,model:'test/model#variant'}})
  assert(options.startOptions(payload,label,'',5).error)
}
assert(options.startOptions(payload,'System default','selected',5).error)
for (const model of ['--auto','a b','a\nb','a\u0000b','$(touch /tmp/forbidden)','x'.repeat(201)]) {
  assert(options.startOptions(payload,'OpenCode',model,6).error)
}
const parent = {parent:'11111111111111111111111111111111',prompt:'Follow-up'}
for (const input of [parent,JSON.stringify(parent)]) {
  assert.deepEqual(copy(options.startOptions(input,'Codex','new-model',5)), {params:{payload:input}})
}
const manifest = require('../../manifest.json')
assert.deepEqual(manifest.barWidget.defaults,{showBarIcon:true})
assert.equal(manifest.barWidget.schema.some(value=>value.key==='aiAgent'),false)
const service = require('fs').readFileSync(require('path').join(__dirname,'../Service.qml'),'utf8')
assert.match(service,/aiAgent: "System default"/)
assert.match(service,/aiModel: ""/)
assert.deepEqual(copy(options.agents()),['System default','OpenCode','Codex','Claude'])
console.log('AI agent/model selection: defaults, API gate, validation and continuation passed')
