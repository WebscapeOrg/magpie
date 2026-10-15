.pragma library
function nextDay(now, weekday) {
  var date = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1, 8, 0, 0, 0)
  while (date.getDay() !== weekday) date.setDate(date.getDate() + 1)
  return date
}
function options(now) {
  return [
    {label:"Tomorrow",date:new Date(now.getFullYear(),now.getMonth(),now.getDate()+1,8,0,0,0)},
    {label:"This weekend",date:nextDay(now,6)},
    {label:"Next week",date:nextDay(now,1)}
  ]
}
function parse(date, hour, minute, now) {
  var match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(date))
  if (!match) return null
  var value = new Date(Number(match[1]),Number(match[2])-1,Number(match[3]),hour,minute,0,0)
  if (value.getFullYear() !== Number(match[1]) || value.getMonth() !== Number(match[2])-1 || value.getDate() !== Number(match[3]) || value.getHours() !== hour || value.getMinutes() !== minute || value.getTime() <= now) return null
  return value
}
