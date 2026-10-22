const assert = require('assert');
const {load} = require('./load');
const S = load('components/Snooze.js');
const I = load('components/MailboxIdentity.js');
for (const day of [new Date(2026,9,15,17),new Date(2026,9,17,9),new Date(2026,9,18,9),new Date(2026,11,31,23)]) {
  const options=S.options(day);
  assert(options.every(v=>v.date>day && v.date.getHours()===8));
  assert.strictEqual(options[1].date.getDay(),6);assert.strictEqual(options[2].date.getDay(),1);
}
assert.strictEqual(S.parse('2026-02-30',8,0,0),null);
assert.strictEqual(S.parse('2026-10-16',8,0,new Date(2026,9,17).getTime()),null);
assert(S.parse('2026-10-16',8,30,0));
assert.strictEqual(I.icon('Webscape'),'tree');assert.strictEqual(I.icon('Personal'),'home');
assert.strictEqual(I.initial({display:'Élodie'}),'É');
assert.strictEqual(I.image('https://example.com/track.png'),'');assert.strictEqual(I.image('file:///etc/passwd'),'');
assert.strictEqual(I.image('data:image/svg+xml;base64,PHN2Zz4='),'');
const raster = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC';
assert.strictEqual(I.image(raster), raster);
assert.strictEqual(I.image('data:image/png;base64,YWJj'), '');
assert.strictEqual(I.image('data:image/png;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPjwvc3ZnPg=='), '');
console.log('Inbox date, identity and image boundary tests passed');
