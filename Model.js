.pragma library
// Pure helpers for the Private Internet Access widget. No QML, no side
// effects — everything here takes plain values and returns plain values so it
// can be exercised from the tests without a running shell.

// piactl connection states. Anything not listed is treated as "busy" so an
// unknown transitional state never renders as connected or disconnected.
var STATES = {
  "Disconnected": { connected: false, busy: false, label: "Disconnected" },
  "Connecting": { connected: false, busy: true, label: "Connecting…" },
  "StillConnecting": { connected: false, busy: true, label: "Still connecting…" },
  "Connected": { connected: true, busy: false, label: "Connected" },
  "Interrupted": { connected: false, busy: true, label: "Interrupted, reconnecting…" },
  "Reconnecting": { connected: false, busy: true, label: "Reconnecting…" },
  "StillReconnecting": { connected: false, busy: true, label: "Still reconnecting…" },
  "DisconnectingToReconnect": { connected: false, busy: true, label: "Switching…" },
  "Disconnecting": { connected: false, busy: true, label: "Disconnecting…" }
}

function stateInfo(raw) {
  var key = String(raw || "").trim()
  if (key === "") return { connected: false, busy: false, label: "Unknown", raw: "" }
  var info = STATES[key]
  if (!info) return { connected: false, busy: true, label: key, raw: key }
  return { connected: info.connected, busy: info.busy, label: info.label, raw: key }
}

// Parse the `key=value` lines emitted by the status script in Service.qml.
// A line starting with `error=` means the script gave up (daemon down, piactl
// missing) and the rest of the value is the message.
function parseStatus(raw) {
  var result = { ok: true, error: "", values: {} }
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/\r$/, "")
    if (line === "") continue
    var eq = line.indexOf("=")
    if (eq < 0) continue
    var key = line.substring(0, eq).trim()
    var value = line.substring(eq + 1).trim()
    if (key === "error") {
      result.ok = false
      result.error = value
      continue
    }
    result.values[key] = value
  }
  return result
}

function parseRegions(raw) {
  var ids = []
  var seen = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var id = lines[i].trim()
    if (id === "" || seen[id]) continue
    seen[id] = true
    ids.push(id)
  }
  return ids
}

function parseBool(value, fallback) {
  var s = String(value === undefined || value === null ? "" : value).trim().toLowerCase()
  if (s === "true" || s === "1" || s === "yes" || s === "on") return true
  if (s === "false" || s === "0" || s === "no" || s === "off") return false
  return fallback
}

// piactl reports "Unknown" for both IPs while disconnected.
function cleanIp(value) {
  var s = String(value || "").trim()
  if (s === "" || /^unknown$/i.test(s)) return ""
  return s
}

// Port forwarding is a port number when active, otherwise one of Inactive,
// Attempting, Failed or Unavailable.
function portForwardInfo(value) {
  var s = String(value || "").trim()
  if (/^\d+$/.test(s)) return { active: true, port: parseInt(s, 10), label: "Port " + s }
  if (s === "" || /^inactive$/i.test(s)) return { active: false, port: 0, label: "Inactive" }
  return { active: false, port: 0, label: s }
}

var COUNTRIES = {
  ad: "Andorra", ae: "United Arab Emirates", af: "Afghanistan", al: "Albania", am: "Armenia",
  ao: "Angola", ar: "Argentina", at: "Austria", au: "Australia", az: "Azerbaijan",
  ba: "Bosnia and Herzegovina", bb: "Barbados", bd: "Bangladesh", be: "Belgium", bg: "Bulgaria",
  bh: "Bahrain", bm: "Bermuda", bn: "Brunei", bo: "Bolivia", br: "Brazil", bs: "Bahamas",
  bt: "Bhutan", bw: "Botswana", by: "Belarus", bz: "Belize", ca: "Canada", ch: "Switzerland",
  cl: "Chile", cm: "Cameroon", cn: "China", co: "Colombia", cr: "Costa Rica", cu: "Cuba",
  cy: "Cyprus", cz: "Czechia", de: "Germany", dk: "Denmark", "do": "Dominican Republic",
  dz: "Algeria", ec: "Ecuador", ee: "Estonia", eg: "Egypt", es: "Spain", et: "Ethiopia",
  fi: "Finland", fj: "Fiji", fr: "France", gb: "United Kingdom", ge: "Georgia", gh: "Ghana",
  gl: "Greenland", gr: "Greece", gt: "Guatemala", hk: "Hong Kong", hn: "Honduras", hr: "Croatia",
  ht: "Haiti", hu: "Hungary", id: "Indonesia", ie: "Ireland", il: "Israel", im: "Isle of Man",
  "in": "India", iq: "Iraq", ir: "Iran", is: "Iceland", it: "Italy", jm: "Jamaica", jo: "Jordan",
  jp: "Japan", ke: "Kenya", kg: "Kyrgyzstan", kh: "Cambodia", kr: "South Korea", kw: "Kuwait",
  kz: "Kazakhstan", la: "Laos", lb: "Lebanon", li: "Liechtenstein", lk: "Sri Lanka", lt: "Lithuania",
  lu: "Luxembourg", lv: "Latvia", ly: "Libya", ma: "Morocco", mc: "Monaco", md: "Moldova",
  me: "Montenegro", mk: "North Macedonia", mm: "Myanmar", mn: "Mongolia", mo: "Macao", mt: "Malta",
  mu: "Mauritius", mv: "Maldives", mx: "Mexico", my: "Malaysia", mz: "Mozambique", na: "Namibia",
  ng: "Nigeria", ni: "Nicaragua", nl: "Netherlands", no: "Norway", np: "Nepal", nz: "New Zealand",
  om: "Oman", pa: "Panama", pe: "Peru", ph: "Philippines", pk: "Pakistan", pl: "Poland",
  pr: "Puerto Rico", pt: "Portugal", py: "Paraguay", qa: "Qatar", ro: "Romania", rs: "Serbia",
  ru: "Russia", rw: "Rwanda", sa: "Saudi Arabia", se: "Sweden", sg: "Singapore", si: "Slovenia",
  sk: "Slovakia", sm: "San Marino", sn: "Senegal", sv: "El Salvador", th: "Thailand", tn: "Tunisia",
  tr: "Türkiye", tt: "Trinidad and Tobago", tw: "Taiwan", tz: "Tanzania", ua: "Ukraine",
  ug: "Uganda", uk: "United Kingdom", us: "United States", uy: "Uruguay", uz: "Uzbekistan",
  va: "Vatican City", ve: "Venezuela", vn: "Vietnam", ye: "Yemen", za: "South Africa",
  zm: "Zambia", zw: "Zimbabwe"
}

// City/suffix spellings piactl uses that a plain title-case would get wrong.
var CITY_FIXES = {
  "siliconvalley": "Silicon Valley",
  "washington-dc": "Washington DC",
  "new-york": "New York",
  "las-vegas": "Las Vegas",
  "streaming-optimized": "Streaming Optimized",
  "east": "East",
  "west": "West"
}

function titleCase(text) {
  return String(text || "").split(/[-_\s]+/).filter(function(p) { return p !== "" }).map(function(part) {
    return part.charAt(0).toUpperCase() + part.substring(1)
  }).join(" ")
}

function cityLabel(suffix) {
  var key = String(suffix || "").toLowerCase()
  if (key === "") return ""
  if (CITY_FIXES[key]) return CITY_FIXES[key]
  return titleCase(key)
}

// "uk" is what PIA used historically; the flag needs the ISO code.
function countryCode(id) {
  var head = String(id || "").toLowerCase().split("-")[0]
  if (head === "uk") return "gb"
  return head
}

function flagFor(id) {
  var code = countryCode(id)
  if (code.length !== 2 || !COUNTRIES[code]) return ""
  var base = 0x1F1E6
  var a = code.charCodeAt(0) - 97
  var b = code.charCodeAt(1) - 97
  if (a < 0 || a > 25 || b < 0 || b > 25) return ""
  return String.fromCodePoint(base + a) + String.fromCodePoint(base + b)
}

function regionParts(id) {
  var raw = String(id || "").trim()
  var lower = raw.toLowerCase()
  if (lower === "" ) return { country: "", city: "", auto: false, dedicated: false }
  if (lower === "auto") return { country: "Automatic", city: "Fastest available", auto: true, dedicated: false }
  if (lower.indexOf("dip-") === 0 || lower.indexOf("dedicated-") === 0) {
    return { country: "Dedicated IP", city: raw, auto: false, dedicated: true }
  }
  var dash = lower.indexOf("-")
  var head = dash < 0 ? lower : lower.substring(0, dash)
  var rest = dash < 0 ? "" : lower.substring(dash + 1)
  var country = COUNTRIES[head]
  if (!country) return { country: titleCase(lower), city: "", auto: false, dedicated: false }
  return { country: country, city: cityLabel(rest), auto: false, dedicated: false }
}

// Human label for a region id, e.g. "us-east" -> "United States · East".
function regionLabel(id) {
  var parts = regionParts(id)
  if (parts.country === "") return "Unknown"
  if (parts.auto) return "Automatic"
  if (parts.city === "") return parts.country
  return parts.country + " · " + parts.city
}

function regionEntry(id) {
  var parts = regionParts(id)
  return {
    id: String(id || ""),
    label: regionLabel(id),
    country: parts.country,
    city: parts.city,
    flag: parts.auto || parts.dedicated ? "" : flagFor(id),
    auto: parts.auto,
    dedicated: parts.dedicated
  }
}

// Build the sorted region catalogue: "auto" first, then dedicated IPs, then
// everything else alphabetically by label.
function regionEntries(ids) {
  var entries = []
  for (var i = 0; i < ids.length; i++) entries.push(regionEntry(ids[i]))
  entries.sort(function(a, b) {
    if (a.auto !== b.auto) return a.auto ? -1 : 1
    if (a.dedicated !== b.dedicated) return a.dedicated ? -1 : 1
    return a.label.localeCompare(b.label)
  })
  return entries
}

function filterRegions(entries, query) {
  var q = String(query || "").trim().toLowerCase()
  if (q === "") return entries
  var terms = q.split(/\s+/)
  var out = []
  for (var i = 0; i < entries.length; i++) {
    var e = entries[i]
    var hay = (e.id + " " + e.label + " " + e.country + " " + e.city).toLowerCase()
    var ok = true
    for (var t = 0; t < terms.length; t++) {
      if (hay.indexOf(terms[t]) === -1) { ok = false; break }
    }
    if (ok) out.push(e)
  }
  return out
}

// Pinned rows under REGIONS: automatic, the current region, then recents.
function pinnedRegions(currentId, recentIds, entries, max) {
  var byId = {}
  for (var i = 0; i < entries.length; i++) byId[entries[i].id] = entries[i]
  var out = []
  var seen = {}
  function push(id) {
    var key = String(id || "")
    if (key === "" || seen[key]) return
    seen[key] = true
    out.push(byId[key] || regionEntry(key))
  }
  push("auto")
  push(currentId)
  var limit = Math.max(0, parseInt(max, 10) || 0)
  var added = 0
  for (var r = 0; r < (recentIds || []).length && added < limit; r++) {
    var before = out.length
    push(recentIds[r])
    if (out.length > before) added++
  }
  return out
}

// Most-recent-first list of region ids, deduplicated and capped. "auto" is
// never recorded since it is always pinned anyway.
function pushRecent(recentIds, id, max) {
  var key = String(id || "")
  var limit = Math.max(0, parseInt(max, 10) || 0)
  if (key === "" || key === "auto" || limit === 0) return (recentIds || []).slice(0, limit)
  var next = [key]
  for (var i = 0; i < (recentIds || []).length && next.length < limit; i++) {
    var existing = String(recentIds[i] || "")
    if (existing !== "" && existing !== key && next.indexOf(existing) === -1) next.push(existing)
  }
  return next
}

function protocolLabel(value) {
  var s = String(value || "").trim().toLowerCase()
  if (s === "wireguard") return "WireGuard"
  if (s === "openvpn") return "OpenVPN"
  return s === "" ? "Unknown" : s
}

function otherProtocol(value) {
  return String(value || "").trim().toLowerCase() === "wireguard" ? "openvpn" : "wireguard"
}

// Collapse whitespace and cap a CLI error so it fits on one panel line.
function elide(text, max) {
  var value = String(text || "").replace(/\s+/g, " ").trim()
  var limit = max || 140
  return value.length > limit ? value.substring(0, limit - 1) + "…" : value
}

function looksLikeLoginError(text) {
  return /not logged in|log in|login|credentials|unauthori[sz]ed/i.test(String(text || ""))
}

function looksLikeDaemonError(text) {
  return /daemon|could not connect|connection refused|not running|no such file/i.test(String(text || ""))
}

function stringSetting(settings, name, fallback) {
  var value = settings ? settings[name] : undefined
  if (value === undefined || value === null) return fallback
  var s = String(value).trim()
  return s === "" ? fallback : s
}

function boolSetting(settings, name, fallback) {
  var value = settings ? settings[name] : undefined
  if (value === undefined || value === null) return fallback
  return parseBool(value, fallback)
}

function intSetting(settings, name, fallback, min, max) {
  var value = settings ? settings[name] : undefined
  var n = parseInt(String(value === undefined || value === null ? fallback : value), 10)
  if (!isFinite(n)) n = fallback
  if (n < min) n = min
  if (n > max) n = max
  return n
}
