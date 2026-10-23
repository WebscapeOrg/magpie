// The existing calendar regression suite supplies independent parity cases.
const loader = require("../ui/tests/load")
const original = loader.load
const cases = []
loader.load = function(path) {
  const library = original(path)
  const names = path === "calendar/Calendar.js"
    ? ["eventsFromGoogle"]
    : []
  for (const name of names) {
    const call = library[name]
    library[name] = function(...args) {
      const result = call(...args)
      if (JSON.stringify([args,result]).length < 100000)
        cases.push({name,args,result})
      return result
    }
  }
  return library
}
console.log = function() {}
require("../ui/tests/test_calendar")
require("../ui/tests/test_calendar_feed")
process.stdout.write(JSON.stringify(cases))
