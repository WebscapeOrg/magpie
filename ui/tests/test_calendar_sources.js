const assert = require('assert')
const { load } = require('./load')
const sources = load('calendar/Sources.js')
const plain = value => JSON.parse(JSON.stringify(value))
const accounts = [
  {id:'one@gmail.com', email:'one@gmail.com', provider:'gmail', signedIn:true},
  {id:'team@example.org', email:'team@example.org', provider:'gmail', signedIn:true},
  {id:'later@gmail.com', provider:'gmail', signedIn:false}
]
const unsupported = [
  {id:'dav', kind:'caldav', url:'https://synthetic.example/calendar/', username:'old', enabled:true, custom:{value:1}},
  {id:'ms', kind:'microsoft', accountId:'outlook:old@example.org', enabled:true},
  {id:'apple', kind:'icloud', accountId:'imap:old@icloud.com', enabled:true},
  {id:'hey', kind:'hey', enabled:true},
  {id:'unknown', kind:'future-provider', enabled:true, custom:['preserved']},
  {id:'missing-kind', custom:true}
]
let saved = sources.load(JSON.stringify({version:1,sources:unsupported}))
assert.deepStrictEqual(plain(saved.sources), unsupported)
assert.deepStrictEqual(JSON.parse(sources.serialize(saved)).sources, unsupported)
for (const source of unsupported) {
  assert.strictEqual(sources.validate(source).ok, false)
  assert.strictEqual(sources.writable(source), false)
  assert.strictEqual(sources.nativeCalendarFeatures(source), false)
  assert.deepStrictEqual(plain(sources.setEnabled(saved, source.id, false)), plain(saved))
  assert.deepStrictEqual(plain(sources.setColor(saved, source.id, 'cyan')), plain(saved))
  assert.deepStrictEqual(plain(sources.remove(saved, source.id)), plain(saved))
}
assert.strictEqual(sources.activeSources(saved).sources.length,0)
assert.strictEqual(sources.calendarEditorUrl(saved),'')
assert.deepStrictEqual(plain(sources.groupByAccount(saved, accounts)), [])
assert.deepStrictEqual(plain(sources.withGoogleAccounts(saved, accounts).sources.map(source=>source.id)),
  ['google:one@gmail.com','google:team@example.org'])
assert.strictEqual(sources.validate({kind:'google',accountId:'one@gmail.com'}).ok,true)
assert.strictEqual(sources.validate({kind:'google',accountId:''}).ok,false)
assert.strictEqual(sources.sourceId({kind:'google',accountId:'one@gmail.com'}),'google:one@gmail.com')

const discovery = {provider:'google',accountId:'one@gmail.com',calendars:[
  {sourceId:'google:one@gmail.com',calendarId:'one@gmail.com',name:'Primary',selected:true,isDefault:true,
   accessRole:'owner',timeZone:'Europe/Paris',canCreateMeet:true,defaultReminders:[{method:'popup',minutes:10}]},
  {sourceId:'google:one:shared',calendarId:'team@example.org',name:'Shared',selected:false,hidden:true,readOnly:true},
  {sourceId:'google:one:work',calendarId:'work@example.org',name:'Work',selected:true,readOnly:false}
]}
saved = sources.applyDiscovery(saved,discovery)
assert.deepStrictEqual(plain(saved.sources.slice(0,unsupported.length)),unsupported)
let active = sources.withGoogleAccounts(saved,accounts)
assert.strictEqual(active.sources.length,4)
const primary = active.sources.find(source=>source.id==='google:one@gmail.com')
assert.strictEqual(primary.calendarId,'one@gmail.com')
assert.strictEqual(primary.accessRole,'owner')
assert.strictEqual(primary.timeZone,'Europe/Paris')
assert.strictEqual(primary.canCreateMeet,true)
assert.strictEqual(primary.defaultReminders[0].minutes,10)
assert.strictEqual(primary.preferred,true)
assert.strictEqual(active.sources.find(source=>source.id==='google:one:shared').enabled,false)
assert.strictEqual(active.sources.find(source=>source.id==='google:one:shared').readOnly,true)
assert.deepStrictEqual(plain(sources.forAccount(active,'team@example.org').sources.map(source=>source.id)),['google:team@example.org'])
assert.strictEqual(sources.forAccount(active,'missing').sources.length,0)
saved = sources.setEnabled(saved,'google:one:shared',true)
saved = sources.setColor(saved,'google:one:shared','cyan')
const rediscovered = sources.applyDiscovery(saved,discovery)
const shared = rediscovered.sources.find(source=>source.id==='google:one:shared')
assert.strictEqual(shared.enabled,true)
assert.strictEqual(shared.colorKey,'cyan')
assert.strictEqual(shared.readOnly,true)
assert.deepStrictEqual(plain(rediscovered.sources.slice(0,unsupported.length)),unsupported)
assert.deepStrictEqual(plain(sources.applyDiscovery(saved,{provider:'icloud',accountId:'one@gmail.com',calendars:[]})),plain(saved))
assert.deepStrictEqual(plain(sources.load(sources.serialize(saved))),plain(saved))
const groups = sources.groupByAccount(sources.withGoogleAccounts(saved,accounts),accounts)
assert.deepStrictEqual(plain(groups.map(group=>group.providerLabel)),['Google','Google'])
assert.deepStrictEqual(plain(groups.map(group=>group.accountLabel)),['one@gmail.com','team@example.org'])
assert.deepStrictEqual(plain(sources.writableGroups(groups)[0].calendars.map(source=>source.id)),['google:one@gmail.com','google:one:work'])
assert.strictEqual(sources.errorLabel(shared,accounts),'Shared · one@gmail.com')
assert.strictEqual(sources.orphaned(shared,accounts),false)
assert.strictEqual(sources.orphaned(shared,[]),true)
assert.strictEqual(sources.calendarEditorUrl(saved),'https://calendar.google.com/calendar/u/0/r/eventedit')
const removed = sources.remove(saved,'google:one:work')
assert.strictEqual(removed.sources.some(source=>source.id==='google:one:work'),false)
assert.deepStrictEqual(plain(removed.sources.slice(0,unsupported.length)),unsupported)
assert.ok(sources.COLOR_KEYS.includes(primary.colorKey))
assert.strictEqual(sources.setColor(saved,'google:one:shared','invalid').sources.find(source=>source.id==='google:one:shared').colorKey,'cyan')
console.log('test_calendar_sources.js ok')
