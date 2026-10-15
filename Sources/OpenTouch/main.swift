import AppKit
import OpenTouchCore

// `OpenTouch --dump` prints what the touch screen sends without moving the pointer.
// Its output is what to attach when reporting an unsupported device.
if CommandLine.arguments.contains("--dump") {
    let hid = HIDService(seize: !CommandLine.arguments.contains("--no-seize"))
    let raw = CommandLine.arguments.contains("--raw")
    var printed = Set<ObjectIdentifier>()
    hid.onDevicesChanged = {
        for d in hid.devices where printed.insert(ObjectIdentifier(d)).inserted {
            print("== \(d.name) \(String(format: "%04X:%04X", d.vendorID, d.productID)) id \(String(d.registryID, radix: 16))")
            print("descriptor: " + d.reportDescriptor.map { String(format: "%02x", $0) }.joined())
            for f in d.decoder.descriptor.fields where f.reportType == .input && f.usagePage < 0xFF00 {
                print("  \(f)")
            }
        }
    }
    hid.onRawReport = { id, payload, d in
        if raw { print("\(String(d.registryID, radix: 16)) report \(id): " + payload.map { String(format: "%02x", $0) }.joined(separator: " ")) }
    }
    hid.onEvent = { event, d in
        print(String(d.registryID, radix: 16), terminator: " ")
        switch event {
        case let .touchFrame(contacts):
            print("touch " + contacts.map { String(format: "#%d %@ (%.3f, %.3f)", $0.id, $0.touching ? "down" : "up", $0.x, $0.y) }
                .joined(separator: "  "))
        case let .pen(p):
            print(String(format: "pen (%.3f, %.3f) range=%d tip=%d barrel=%d eraser=%d pressure=%.3f tilt=(%.2f, %.2f)",
                         p.x, p.y, p.inRange ? 1 : 0, p.tip ? 1 : 0, p.barrel ? 1 : 0, p.eraser ? 1 : 0,
                         p.pressure, p.tiltX ?? 0, p.tiltY ?? 0))
        }
    }
    hid.start()
    print("Listening for touch screens and pens. Ctrl-C to stop.")
    setvbuf(stdout, nil, _IOLBF, 0)
    CFRunLoopRun()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
