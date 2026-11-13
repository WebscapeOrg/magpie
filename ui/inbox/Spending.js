.pragma library

// Presentation rules for Settings → AI spending, the same rules as the iPhone's page
// (magpie-mail-ios Core/Sources/MagpieCore/Spending.swift). The amounts come from ai.spending, in
// billionths of a dollar. On Linux only sender pictures are counted: AI descriptions and Ask
// Magpie run through the selected agent, not Magpie's own key.

var PERIODS = [
  {id: "day", title: "Today", phrase: "today"},
  {id: "week", title: "This week", phrase: "this week"},
  {id: "month", title: "This month", phrase: "this month"}
]

var WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
var MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August",
  "September", "October", "November", "December"]

// When today, this week and this month began on this computer's clock, in milliseconds since
// 1970: ai.spending's parameters. firstDay is QML's Locale.firstDayOfWeek (0 is Sunday).
function starts(now, firstDay) {
  var first = Number(firstDay)
  if (!(first >= 0 && first <= 6)) first = 1
  var back = (now.getDay() - first + 7) % 7
  return {
    day: midnight(now.getFullYear(), now.getMonth(), now.getDate()),
    week: midnight(now.getFullYear(), now.getMonth(), now.getDate() - back),
    month: midnight(now.getFullYear(), now.getMonth(), 1)
  }
}

// The first instant of a local day, in milliseconds since 1970. Where summer time skips or repeats
// midnight, JavaScript engines disagree about new Date(y, m, d): Qt's moves a skipped midnight back
// into the day before. So this steps by quarter hours from there to the first one on the day.
function midnight(year, month, date) {
  var target = new Date(year, month, date, 12).getDate()
  var at = new Date(year, month, date).getTime()
  while (new Date(at).getDate() !== target) at += 900000
  while (new Date(at - 900000).getDate() === target) at -= 900000
  return at
}

// One feature's amount in one period of an ai.spending reply; anything else reads as nothing.
function amount(reply, period, feature) {
  var periods = reply && typeof reply === "object" ? reply.periods : null
  var value = periods && typeof periods === "object" && periods[period] && typeof periods[period] === "object"
    ? Number(periods[period][feature]) : 0
  return isFinite(value) && value > 0 ? value : 0
}

// Dollars and cents. An amount under half a cent that is not nothing reads as under a cent, so it
// does not look free.
function money(nanodollars) {
  var value = Number(nanodollars)
  var cents = isFinite(value) && value > 0 ? value / 10000000 : 0
  if (cents > 0 && cents < 0.5) return "under $0.01"
  return "$" + (Math.round(cents) / 100).toFixed(2)
}

function pad(number) {
  return number < 10 ? "0" + number : String(number)
}

// Said only while counting began after the earliest period started, so that period is not
// complete. since and the starts are milliseconds since 1970.
function note(since, periodStarts, now) {
  var began = Number(since)
  if (since === null || since === undefined || !isFinite(began) || !periodStarts) return ""
  var earliest = Math.min(periodStarts.day, periodStarts.week, periodStarts.month)
  if (!(began > earliest)) return ""
  var at = new Date(began)
  var time = pad(at.getHours()) + ":" + pad(at.getMinutes())
  var startOfBegan = new Date(at.getFullYear(), at.getMonth(), at.getDate())
  var startOfNow = new Date(now.getFullYear(), now.getMonth(), now.getDate())
  var days = Math.round((startOfNow.getTime() - startOfBegan.getTime()) / 86400000)
  var when
  if (days <= 0) when = "today at " + time
  else if (days === 1) when = "yesterday at " + time
  else if (days < 7) when = "on " + WEEKDAYS[at.getDay()] + " at " + time
  else when = "on " + at.getDate() + " " + MONTHS[at.getMonth()]
  return "Magpie Mail began counting " + when + ", so spending before then is not included."
}

function footer(reply, periodStarts, now) {
  var parts = []
  var counted = note(reply && typeof reply === "object" ? reply.since : null, periodStarts, now)
  if (counted !== "") parts.push(counted)
  parts.push("Sender pictures painted on this computer, estimated at OpenAI's list prices; your OpenAI "
    + "account shows the exact amounts. Descriptions and Ask Magpie Mail use the agent chosen under AI, and "
    + "the iPhone and iPad count their own.")
  return parts.join(" ")
}
