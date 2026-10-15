const assert = require('assert');
const {load} = require('./load');
const S = load('components/Snooze.js');
const I = load('components/MailboxIdentity.js');
for (const day of [new Date(2026,9,15,17),new Date(2026,9,17,9),new Date(2026,9,18,9),new Date(2026,11,31,23)]) {
  const options=S.options(day);
  assert(options.every(v=>v.date>day && v.date.getHours()===8));
  assert.equal(options[1].date.getDay(),6);assert.equal(options[2].date.getDay(),1);
}
assert.equal(S.parse('2026-02-30',8,0,0),null);
assert.equal(S.parse('2026-10-16',8,0,new Date(2026,9,17).getTime()),null);
assert(S.parse('2026-10-16',8,30,0));
assert.equal(I.icon('Webscape'),'tree');assert.equal(I.icon('Personal'),'home');
assert.equal(I.initial({display:'Élodie'}),'É');
assert.equal(I.image('https://example.com/track.png'),'');assert.equal(I.image('file:///etc/passwd'),'');
assert.equal(I.image('data:image/svg+xml;base64,PHN2Zz4='),'');
assert.equal(I.image('data:image/png;base64,YWJj'),'data:image/png;base64,YWJj');
console.log('Inbox date, identity and image boundary tests passed');
