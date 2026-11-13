.pragma library

function selectable(entry) {
  return !!entry && entry.selectable !== false && entry.visible !== false && entry.enabled !== false
}

function firstSelectable(entries) {
  var values = Array.isArray(entries) ? entries : []
  for (var rowIndex = 0; rowIndex < values.length; rowIndex++) if (selectable(values[rowIndex])) return rowIndex
  return -1
}

function nextSelectable(entries, current, step) {
  var values = Array.isArray(entries) ? entries : []
  if (values.length === 0) return -1
  var direction = Number(step) < 0 ? -1 : 1
  var selectedIndex = Math.floor(Number(current))
  if (!isFinite(selectedIndex) || selectedIndex < 0 || selectedIndex >= values.length) selectedIndex = direction > 0 ? -1 : 0
  for (var attempt = 0; attempt < values.length; attempt++) {
    selectedIndex = (selectedIndex + direction + values.length) % values.length
    if (selectable(values[selectedIndex])) return selectedIndex
  }
  return -1
}

function position(anchorX, anchorY, width, height, containerWidth, containerHeight) {
  var positionX = Math.max(0, Math.min(Number(anchorX), Number(containerWidth) - Number(width)))
  var positionY = Number(anchorY)
  if (positionY + height > containerHeight) positionY = positionY - height
  if (positionY + height > containerHeight) positionY = containerHeight - height
  return { x: Math.max(0, positionX), y: Math.max(0, positionY) }
}
