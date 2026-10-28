.pragma library

// The visible color or border-width control always patches its paired flag
// atomically. The caller supplies the interaction snapshot for both keys.
function pairPatch(key, pairedWith, value, enabled) {
  var patch = Object.create(null)
  patch[key] = value
  patch[pairedWith] = enabled === true
  return patch
}
function pairExpected(key, pairedWith, value, enabled) {
  var expected = Object.create(null)
  expected[key] = value
  expected[pairedWith] = enabled === true
  return expected
}
function validHex(value) {
  return typeof value === "string"
    && /^#[0-9a-fA-F]{6}(?:[0-9a-fA-F]{2})?$/.test(value)
}
function colorOptions() {
  return [{value:"default",label:"Theme default"},
    {value:"@accent",label:"Theme accent"},
    {value:"@foreground",label:"Theme foreground"},
    {value:"@menu.background",label:"Theme menu background"},
    {value:"custom",label:"Custom hex…"}]
}
