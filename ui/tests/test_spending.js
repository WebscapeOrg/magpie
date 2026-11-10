const assert = require("assert")
const { load } = require("./load")

const spending = load("inbox/Spending.js")

// Periods start at local midnight; the week starts on the locale's first day.
const tuesday = new Date(2026, 10, 3, 9, 41, 12)
assert.deepStrictEqual({ ...spending.starts(tuesday, 1) }, {
  day: new Date(2026, 10, 3).getTime(),
  week: new Date(2026, 10, 2).getTime(),
  month: new Date(2026, 10, 1).getTime()
})
assert.strictEqual(spending.starts(tuesday, 0).week, new Date(2026, 10, 1).getTime(), "a Sunday-first week")
assert.strictEqual(spending.starts(tuesday, 2).week, new Date(2026, 10, 3).getTime(), "today is the first day")
assert.strictEqual(spending.starts(tuesday, 3).week, new Date(2026, 9, 28).getTime(), "a week that began last month")
assert.strictEqual(spending.starts(tuesday, undefined).week, new Date(2026, 10, 2).getTime(), "Monday when unknown")
assert.strictEqual(spending.starts(tuesday, 9).week, new Date(2026, 10, 2).getTime())
const firstOfMonth = new Date(2026, 11, 1, 0, 5)
assert.strictEqual(spending.starts(firstOfMonth, 1).month, new Date(2026, 11, 1).getTime())
assert.strictEqual(spending.starts(firstOfMonth, 1).day, new Date(2026, 11, 1).getTime())

// Money: the iPhone's rules.
assert.strictEqual(spending.money(0), "$0.00")
assert.strictEqual(spending.money(1), "under $0.01")
assert.strictEqual(spending.money(4999999), "under $0.01")
assert.strictEqual(spending.money(5000000), "$0.01")
assert.strictEqual(spending.money(1841000000), "$1.84")
assert.strictEqual(spending.money(-5), "$0.00")
assert.strictEqual(spending.money("x"), "$0.00")
assert.strictEqual(spending.money(Infinity), "$0.00")

// Amounts: anything malformed reads as nothing.
const reply = { periods: { day: { pictures: 120000000 }, week: { pictures: "x" }, month: { pictures: -4 } }, since: null }
assert.strictEqual(spending.amount(reply, "day", "pictures"), 120000000)
assert.strictEqual(spending.amount(reply, "week", "pictures"), 0)
assert.strictEqual(spending.amount(reply, "month", "pictures"), 0)
assert.strictEqual(spending.amount(null, "day", "pictures"), 0)
assert.strictEqual(spending.amount({ periods: { day: null } }, "day", "pictures"), 0)
assert.strictEqual(spending.amount({ periods: "x" }, "day", "pictures"), 0)

// The note appears only while counting began after the earliest period started.
const starts = spending.starts(tuesday, 1)
assert.strictEqual(spending.note(null, starts, tuesday), "")
assert.strictEqual(spending.note(new Date(2026, 9, 20).getTime(), starts, tuesday), "")
assert.strictEqual(spending.note(new Date(2026, 10, 1).getTime(), starts, tuesday), "")
assert.strictEqual(spending.note(new Date(2026, 10, 3, 8, 5).getTime(), starts, tuesday),
  "Magpie began counting today at 08:05, so spending before then is not included.")
assert.strictEqual(spending.note(new Date(2026, 10, 2, 17, 30).getTime(), starts, tuesday),
  "Magpie began counting yesterday at 17:30, so spending before then is not included.")
assert.strictEqual(spending.note(new Date(2026, 10, 1, 7, 0, 1).getTime(), starts, tuesday),
  "Magpie began counting on Sunday at 07:00, so spending before then is not included.")
const later = new Date(2026, 11, 20, 9, 0)
assert.strictEqual(spending.note(new Date(2026, 10, 3, 8, 5).getTime(), spending.starts(later, 1), later), "",
  "every period began after counting did")
const monthEnd = new Date(2026, 10, 30, 9, 0)
assert.strictEqual(spending.note(new Date(2026, 10, 3, 8, 5).getTime(), { day: monthEnd.getTime(), week: monthEnd.getTime(), month: monthEnd.getTime() - 86400000 }, monthEnd), "")
assert.strictEqual(spending.note(new Date(2026, 10, 12, 8, 5).getTime(), spending.starts(new Date(2026, 10, 30, 9), 1), new Date(2026, 10, 30, 9)),
  "Magpie began counting on 12 November, so spending before then is not included.")

// A week that began last month is the earliest period, so counting that began after it is noted.
const wednesdayWeek = spending.starts(tuesday, 3)
assert.strictEqual(wednesdayWeek.week, new Date(2026, 9, 28).getTime())
assert.strictEqual(spending.note(new Date(2026, 9, 30, 10, 0).getTime(), wednesdayWeek, tuesday),
  "Magpie began counting on Friday at 10:00, so spending before then is not included.")

// Six days back is named by its weekday, seven by its date.
const friday = new Date(2026, 10, 20, 9, 0)
const fridayStarts = spending.starts(friday, 1)
assert.strictEqual(spending.note(new Date(2026, 10, 14, 9, 0).getTime(), fridayStarts, friday),
  "Magpie began counting on Saturday at 09:00, so spending before then is not included.")
assert.strictEqual(spending.note(new Date(2026, 10, 13, 9, 0).getTime(), fridayStarts, friday),
  "Magpie began counting on 13 November, so spending before then is not included.")

// Every start is the first instant of its local day, also where summer time skips or repeats
// midnight (the Makefile runs the QML test of this in such zones too).
function firstInstant(at, date) {
  assert.strictEqual(new Date(at).getDate(), date)
  assert.notStrictEqual(new Date(at - 1).getDate(), date)
}
const springForward = spending.starts(new Date(2026, 8, 6, 10), 1)
firstInstant(springForward.day, 6)
firstInstant(springForward.week, 31)
firstInstant(springForward.month, 1)
const fallBack = spending.starts(new Date(2026, 10, 3, 10), 0)
firstInstant(fallBack.day, 3)
firstInstant(fallBack.week, 1)
firstInstant(fallBack.month, 1)

// The footer names what is and is not counted, and never claims the amounts are a bill.
const footer = spending.footer(reply, starts, tuesday)
assert.ok(footer.startsWith("Sender pictures painted on this computer, estimated at OpenAI's list prices"))
assert.ok(footer.includes("Descriptions and Ask Magpie use the agent chosen under AI"))
assert.ok(spending.footer({ since: new Date(2026, 10, 3, 8, 5).getTime() }, starts, tuesday)
  .startsWith("Magpie began counting today at 08:05"))
assert.ok(spending.footer(null, null, tuesday).startsWith("Sender pictures painted"))

console.log("spending: ok")
