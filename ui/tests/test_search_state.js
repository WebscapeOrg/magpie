const assert = require('node:assert/strict')
const { load, deepEqual } = require('./load')
const Search = load('account/SearchState.js')

function row(id, dateMs, pendingEdit, matchesQuery) {
  return { id, dateMs, pendingEdit: !!pendingEdit, matchesQuery, pendingLabelMatch: matchesQuery }
}

const confirmed = [row('new', 20), row('old', 10)]
let overlay = Search.overlay({}, [row('new', 20, true, false), row('added', 30, true, true)])
deepEqual(Search.merge(confirmed, overlay).map(value => value.id), ['added', 'old'])
assert.equal(Search.pendingCount(overlay), 2)
overlay = Search.overlay(overlay, [row('new', 20, false, true), row('added', 30, false, false)])
deepEqual(Search.merge(confirmed, overlay).map(value => value.id), ['added', 'old'], 'an older server snapshot cannot reverse an acknowledged edit')
assert.equal(Search.pendingCount(overlay), 0)

overlay = Search.overlay({}, [row('unknown', 40, true, null)])
deepEqual(Search.merge(confirmed, overlay).map(value => value.id), ['new', 'old'], 'unknown local membership never invents a server match')
deepEqual(Search.merge([row('unknown', 2)], overlay).map(value => value.dateMs), [40], 'confirmed membership can use current effective metadata')
deepEqual(Search.merge([], {}).map(value => value.id), [], 'successful empty server membership removes all provisional rows')
deepEqual(Search.combine(confirmed, [row('old', 50)]).map(value => value.id), ['old', 'new'])

const specialIds = ['__proto__', 'constructor', 'toString', 'hasOwnProperty']
const specialRows = specialIds.map((id, index) => row(id, 100 - index))
deepEqual(Search.merge(specialRows, {}).map(value => value.id), specialIds, 'prototype names remain ordinary confirmed message IDs')
deepEqual(Search.combine([], specialRows).map(value => value.id), specialIds)
const objectPrototype = Object.getPrototypeOf({})
const inherited = Object.create({ unrelated: { row: row('unrelated', 500, true, true), include: true } })
overlay = Search.overlay(inherited, specialRows.map(value => Object.assign({}, value, { pendingEdit: true, matchesQuery: true, pendingLabelMatch: true })))
assert.equal(Object.getPrototypeOf(overlay), null)
assert.equal(Search.pendingCount(overlay), specialIds.length)
deepEqual(Search.merge([], overlay).map(value => value.id), specialIds, 'special IDs can be added by pending edits without inherited entries')
deepEqual(Search.merge(specialRows, inherited).map(value => value.id), specialIds, 'inherited overlay entries never affect message membership')
assert.equal(Search.pendingCount(inherited), 0)
const copied = Search.overlay(overlay, [])
assert.equal(Object.getPrototypeOf(copied), null)
deepEqual(Search.merge([], copied).map(value => value.id), specialIds, 'copying keeps an own __proto__ entry')
overlay = Search.overlay(copied, specialRows)
assert.equal(Search.pendingCount(overlay), 0)
deepEqual(Search.merge([], overlay).map(value => value.id), specialIds, 'acknowledgement preserves special-ID membership')
overlay = Search.overlay(overlay, [row('__proto__', 100, true, false)])
deepEqual(Search.merge(specialRows, overlay).map(value => value.id), specialIds.slice(1), 'removing __proto__ affects only that message')
overlay = Search.overlay(overlay, [row('__proto__', 100, false, true)])
deepEqual(Search.merge(specialRows, overlay).map(value => value.id), specialIds.slice(1), 'acknowledged removal remains scoped to that message')
assert.equal(Object.getPrototypeOf(overlay), null)
assert.equal(Object.getPrototypeOf({}), objectPrototype)
assert.equal(Object.prototype.row, undefined)
assert.equal(Object.prototype.include, undefined)

let status = Search.aggregate([
  Search.status('complete', '', '', 0),
  Search.status('checking', '', '', 1)
], 'Gmail accounts · 2 of 3 accounts searched')
assert.equal(status.phase, 'checking')
assert.equal(status.canStop, true)
assert.equal(status.pendingCount, 1)
status = Search.aggregate([
  Search.status('complete', '', '', 0),
  Object.assign(Search.status('failed', 'Sign in again.', 'gmail_unauthorized', 0), {label:'Second'})
], '')
assert.equal(status.phase, 'partial')
assert.equal(status.canRetry, true)
assert.equal(status.error, 'Second: Sign in again.')
assert.equal(status.errorCode, 'gmail_unauthorized')
console.log('search state: pending edits, exact membership, result order and multi-account status passed')
