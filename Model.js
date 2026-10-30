.pragma library

// MCCS VCP codes the panel uses. Continuous ones are levels with a maximum.
// The rest pick one value from the list the monitor advertises.
var BRIGHTNESS = "10"
var CONTRAST = "12"
var COLOR_PRESET = "14"
var INPUT = "60"
var VOLUME = "62"
var POWER = "D6"
var PICTURE_MODE = "DC"

var READ_CODES = [BRIGHTNESS, CONTRAST, COLOR_PRESET, INPUT, VOLUME, PICTURE_MODE]
var CHOICE_CODES = [COLOR_PRESET, INPUT, POWER, PICTURE_MODE]

// Labels from the MCCS 2.2 tables. 0x1B is outside the standard, but Dell, HP
// and Lenovo all use it for USB-C. Anything else shows as its raw hex.
var LABELS = {
    "60": {
        "01": "VGA 1", "02": "VGA 2", "03": "DVI 1", "04": "DVI 2",
        "05": "Composite 1", "06": "Composite 2", "07": "S-Video 1", "08": "S-Video 2",
        "0C": "Component 1", "0D": "Component 2", "0E": "Component 3",
        "0F": "DP 1", "10": "DP 2", "11": "HDMI 1", "12": "HDMI 2", "1B": "USB-C"
    },
    "14": {
        "01": "sRGB", "02": "Native", "03": "4000K", "04": "5000K", "05": "6500K",
        "06": "7500K", "07": "8200K", "08": "9300K", "09": "10000K", "0A": "11500K",
        "0B": "User 1", "0C": "User 2", "0D": "User 3"
    },
    "DC": {
        "00": "Standard", "01": "Productivity", "02": "Mixed", "03": "Movie",
        "04": "User", "05": "Games", "06": "Sports", "07": "Professional",
        "08": "Standard", "09": "Demo", "F0": "Dynamic contrast"
    }
}

function hex(value) {
    var s = String(value || "").toUpperCase()
    return s.length === 1 ? "0" + s : s
}

// `ddcutil detect --terse` prints one block per display. Blocks that start with
// "Invalid display" are monitors that do not answer DDC/CI. The connector comes
// as card1-HDMI-A-1, and Hyprland calls it HDMI-A-1.
function parseDetect(text) {
    var list = []
    var blocks = String(text || "").split(/\n(?=\S)/)
    for (var i = 0; i < blocks.length; i++) {
        var block = blocks[i]
        if (!/^Display \d+/.test(block)) continue
        var bus = /I2C bus:\s*\/dev\/i2c-(\d+)/.exec(block)
        var connector = /DRM[ _]connector:\s*(\S+)/.exec(block)
        var monitor = /Monitor:\s*([^\n]*)/.exec(block)
        if (!bus) continue
        var parts = monitor ? monitor[1].split(":") : []
        list.push({
            bus: bus[1],
            connector: connector ? connector[1].replace(/^card\d+-/, "") : "",
            model: (parts[1] || "").trim(),
            serial: (parts[2] || "").trim(),
            id: monitor ? monitor[1].trim() : "bus" + bus[1]
        })
    }
    return list
}

// `ddcutil capabilities --terse` prints the raw MCCS string. Its vcp(...) group
// lists every code, each optionally followed by its allowed values in parens.
// Returns { "10": [], "60": ["1B", "11", "12"], ... }.
function parseCapabilities(text) {
    var s = String(text || "")
    var start = s.indexOf("vcp(")
    if (start < 0) return {}
    var depth = 0
    var body = ""
    for (var i = start + 3; i < s.length; i++) {
        var c = s[i]
        if (c === "(") { depth++; if (depth === 1) continue }
        if (c === ")") { depth--; if (depth === 0) break }
        body += c
    }
    var caps = {}
    var re = /([0-9A-Fa-f]{2})\s*(?:\(([^)]*)\))?/g
    var m
    while ((m = re.exec(body)) !== null) {
        var values = (m[2] || "").trim()
        caps[hex(m[1])] = values === "" ? [] : values.split(/\s+/).map(hex)
    }
    return caps
}

// `ddcutil getvcp ... --brief` lines: "VCP 10 C 94 100" for a level,
// "VCP 60 SNC x11" for a choice, "VCP DC ERR" when the read failed.
function parseValues(text) {
    var values = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
        var f = lines[i].trim().split(/\s+/)
        if (f[0] !== "VCP" || f.length < 4) continue
        var code = hex(f[1])
        if (f[2] === "C" && f.length >= 5)
            values[code] = { current: parseInt(f[3], 10), max: parseInt(f[4], 10) }
        else if (f[2] === "SNC" && /^x[0-9A-Fa-f]+$/.test(f[3]))
            values[code] = { value: hex(f[3].slice(1)) }
    }
    return values
}

function clampPercent(value) {
    var v = Math.round(Number(value))
    if (!isFinite(v)) return 0
    return Math.max(0, Math.min(100, v))
}

function percentOf(level) {
    if (!level || !(level.max > 0)) return -1
    return clampPercent(level.current * 100 / level.max)
}

function rawFromPercent(percent, max) {
    return Math.round(clampPercent(percent) * max / 100)
}

function options(code, values) {
    var labels = LABELS[code] || {}
    return (values || []).map(function(v) {
        return { value: v, label: labels[v] || "0x" + v }
    })
}

// 0x05 switches the monitor off like its power button. 0x04 is the DPM standby
// some monitors offer instead, which wakes on the next signal.
function powerOffValue(values) {
    var list = values || []
    if (list.indexOf("05") >= 0) return "05"
    if (list.indexOf("04") >= 0) return "04"
    return ""
}

function sameJob(a, b) {
    if (a.kind !== b.kind) return false
    if (a.kind === "detect") return true
    if (a.bus !== b.bus) return false
    return a.kind !== "write" || a.code === b.code
}

// A newer write to the same control replaces the queued one in place. A drag
// then sends only where it ended. A queued read, capabilities query or detect
// already covers a repeat of itself.
function enqueue(queue, job) {
    var next = queue.slice()
    for (var i = 0; i < next.length; i++) {
        if (sameJob(next[i], job)) {
            next[i] = job
            return next
        }
    }
    next.push(job)
    return next
}

function hasPendingWrite(queue, bus, code) {
    for (var i = 0; i < queue.length; i++)
        if (queue[i].kind === "write" && queue[i].bus === bus && queue[i].code === code) return true
    return false
}

function command(job) {
    if (job.kind === "detect") return ["ddcutil", "detect", "--terse"]
    if (job.kind === "caps") return ["ddcutil", "--bus", job.bus, "capabilities", "--terse"]
    if (job.kind === "read")
        return ["ddcutil", "--bus", job.bus, "getvcp"].concat(job.codes || READ_CODES, ["--brief"])
    var value = CHOICE_CODES.indexOf(job.code) >= 0 ? "0x" + job.value : String(job.value)
    return ["ddcutil", "--bus", job.bus, "--noverify", "setvcp", job.code, value]
}

// PipeWire names an HDMI/DP sink after the monitor's EDID: node.nick is the
// bare model, and node.description carries it in brackets.
function isMonitorSink(sink, model) {
    if (!sink || !model) return false
    return String(sink.nickname || "") === model
        || String(sink.description || "").indexOf("[" + model + "]") !== -1
}
