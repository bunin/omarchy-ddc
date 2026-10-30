import QtQuick
import QtTest
import "../Model.js" as Model

TestCase {
    name: "Model"

    readonly property string detectOne: "Display 1\n"
        + "   I2C bus:          /dev/i2c-3\n"
        + "   DRM connector:    card1-HDMI-A-1\n"
        + "   drm_connector_id: 1216\n"
        + "   Monitor:          DEL:DELL S2722QC:ABC1234\n\n"

    function test_parse_detect() {
        var list = Model.parseDetect(detectOne)
        compare(list.length, 1)
        compare(list[0].bus, "3")
        compare(list[0].connector, "HDMI-A-1")
        compare(list[0].model, "DELL S2722QC")
        compare(list[0].serial, "ABC1234")
        compare(list[0].id, "DEL:DELL S2722QC:ABC1234")
    }

    function test_parse_detect_skips_invalid_and_keeps_order() {
        var text = detectOne
            + "Invalid display\n"
            + "   I2C bus:          /dev/i2c-5\n"
            + "   DRM connector:    card1-DP-1\n"
            + "   Monitor:          GSM:LG HDR 4K:\n\n"
            + "Display 2\n"
            + "   I2C bus:          /dev/i2c-7\n"
            + "   DRM connector:    card0-DP-2\n"
            + "   Monitor:          GSM:LG HDR 4K:\n"
        var list = Model.parseDetect(text)
        compare(list.length, 2)
        compare(list[1].bus, "7")
        compare(list[1].connector, "DP-2")
        compare(list[1].model, "LG HDR 4K")
        compare(list[1].serial, "")
        compare(Model.parseDetect("").length, 0)
        compare(Model.parseDetect(undefined).length, 0)
        compare(Model.parseDetect("No displays found").length, 0)
    }

    function test_parse_capabilities() {
        var caps = Model.parseCapabilities("Unparsed capabilities string: (prot(monitor)type(LCD)model(S2722QC)cmds(01 02 03 07 0C E3 F3)vcp(02 04 05 08 10 12 14(05 08 0B 0C) 16 18 1A 52 60(1B 11 12 ) 62 AC AE B2 B6 C6 C8 C9 CA CC(02 0A 03 04 08 09 0D 06 ) D6(01 04 05) DC(00 03 05 ) DF E0 E2(00 02 22 ) F0(0F 10 11 31 32 34 ) FD)mswhql(1)asset_eep(40)mccs_ver(2.1))")
        compare(caps["10"], [])
        compare(caps["12"], [])
        compare(caps["14"], ["05", "08", "0B", "0C"])
        compare(caps["60"], ["1B", "11", "12"])
        compare(caps["62"], [])
        compare(caps["D6"], ["01", "04", "05"])
        compare(caps["DC"], ["00", "03", "05"])
        compare(caps["8D"], undefined)
    }

    function test_parse_capabilities_lowercase_and_garbage() {
        var caps = Model.parseCapabilities("(vcp(10 12 60(0f 11)))")
        compare(caps["60"], ["0F", "11"])
        compare(Object.keys(Model.parseCapabilities("")).length, 0)
        compare(Object.keys(Model.parseCapabilities("DDC communication failed")).length, 0)
    }

    function test_parse_values() {
        var v = Model.parseValues("VCP 10 C 94 100\nVCP 12 C 88 100\nVCP 14 SNC x05\nVCP 60 SNC x11\nVCP 62 C 25 50\nVCP DC ERR\n")
        compare(v["10"], { current: 94, max: 100 })
        compare(v["62"], { current: 25, max: 50 })
        compare(v["14"], { value: "05" })
        compare(v["60"], { value: "11" })
        compare(v["DC"], undefined)
        compare(Object.keys(Model.parseValues("")).length, 0)
    }

    function test_percent() {
        compare(Model.percentOf({ current: 94, max: 100 }), 94)
        compare(Model.percentOf({ current: 25, max: 50 }), 50)
        compare(Model.percentOf({ current: 5, max: 0 }), -1)
        compare(Model.percentOf(undefined), -1)
        compare(Model.rawFromPercent(50, 50), 25)
        compare(Model.rawFromPercent(33, 255), 84)
        compare(Model.rawFromPercent(120, 100), 100)
        compare(Model.rawFromPercent(-3, 100), 0)
    }

    function test_options() {
        compare(Model.options("60", ["1B", "11", "12", "F4"]), [
            { value: "1B", label: "USB-C" },
            { value: "11", label: "HDMI 1" },
            { value: "12", label: "HDMI 2" },
            { value: "F4", label: "0xF4" }
        ])
        compare(Model.options("14", ["05", "0B"]), [
            { value: "05", label: "6500K" },
            { value: "0B", label: "User 1" }
        ])
        compare(Model.options("DC", ["00", "05"]), [
            { value: "00", label: "Standard" },
            { value: "05", label: "Games" }
        ])
        compare(Model.options("60", undefined), [])
    }

    function test_power_off_value() {
        compare(Model.powerOffValue(["01", "04", "05"]), "05")
        compare(Model.powerOffValue(["01", "04"]), "04")
        compare(Model.powerOffValue(["01"]), "")
        compare(Model.powerOffValue(undefined), "")
    }

    function test_enqueue_coalesces_writes() {
        var q = []
        q = Model.enqueue(q, { kind: "write", bus: "3", code: "10", value: "40" })
        q = Model.enqueue(q, { kind: "write", bus: "3", code: "12", value: "50" })
        q = Model.enqueue(q, { kind: "write", bus: "3", code: "10", value: "45" })
        q = Model.enqueue(q, { kind: "write", bus: "7", code: "10", value: "60" })
        compare(q.length, 3)
        compare(q[0].value, "45")
        compare(q[1].code, "12")
        compare(q[2].bus, "7")
    }

    function test_enqueue_dedupes_reads_and_detect() {
        var q = []
        q = Model.enqueue(q, { kind: "detect" })
        q = Model.enqueue(q, { kind: "read", bus: "3" })
        q = Model.enqueue(q, { kind: "detect" })
        q = Model.enqueue(q, { kind: "read", bus: "3" })
        q = Model.enqueue(q, { kind: "caps", bus: "3" })
        q = Model.enqueue(q, { kind: "caps", bus: "3" })
        compare(q.length, 3)
        compare(q[0].kind, "detect")
        compare(q[1].kind, "read")
        compare(q[2].kind, "caps")
    }

    function test_pending_write() {
        var q = [{ kind: "write", bus: "3", code: "10", value: "40" }]
        compare(Model.hasPendingWrite(q, "3", "10"), true)
        compare(Model.hasPendingWrite(q, "3", "12"), false)
        compare(Model.hasPendingWrite(q, "7", "10"), false)
    }

    function test_command() {
        compare(Model.command({ kind: "detect" }), ["ddcutil", "detect", "--terse"])
        compare(Model.command({ kind: "caps", bus: "3" }), ["ddcutil", "--bus", "3", "capabilities", "--terse"])
        compare(Model.command({ kind: "read", bus: "3", codes: ["10", "60"] }),
                ["ddcutil", "--bus", "3", "getvcp", "10", "60", "--brief"])
        compare(Model.command({ kind: "write", bus: "3", code: "60", value: "11" }),
                ["ddcutil", "--bus", "3", "--noverify", "setvcp", "60", "0x11"])
        compare(Model.command({ kind: "write", bus: "3", code: "10", value: "40" }),
                ["ddcutil", "--bus", "3", "--noverify", "setvcp", "10", "40"])
    }

    function test_is_monitor_sink() {
        var dell = { nickname: "DELL S2722QC", description: "GB203 High Definition Audio Controller Digital Stereo (HDMI) [DELL S2722QC]" }
        compare(Model.isMonitorSink(dell, "DELL S2722QC"), true)
        compare(Model.isMonitorSink({ nickname: "", description: dell.description }, "DELL S2722QC"), true)
        compare(Model.isMonitorSink({ nickname: "ALC887-VD Digital", description: "Starship/Matisse HD Audio Controller Digital Stereo (IEC958)" }, "DELL S2722QC"), false)
        compare(Model.isMonitorSink(null, "DELL S2722QC"), false)
        compare(Model.isMonitorSink(dell, ""), false)
    }
}
