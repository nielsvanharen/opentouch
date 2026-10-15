import Testing
@testable import OpenTouchCore

/// A typical Windows-compatible descriptor: a two-finger hybrid-mode touch screen
/// (report 1), its configuration collection (report 3) and an active pen (report 4).
let sampleDescriptor: [UInt8] = {
    let finger: [UInt8] = [
        0x09, 0x22, 0xA1, 0x02,                         // Finger, logical
        0x09, 0x42, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x01, 0x81, 0x02, // Tip switch
        0x09, 0x47, 0x81, 0x02,                         // Confidence
        0x95, 0x06, 0x81, 0x03,                         // Padding
        0x09, 0x51, 0x25, 0x0F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x02, // Contact ID
        0x05, 0x01, 0x26, 0xFF, 0x0F, 0x75, 0x10,       // X/Y 0...4095
        0x09, 0x30, 0x81, 0x02, 0x09, 0x31, 0x81, 0x02,
        0x05, 0x0D, 0xC0,
    ]
    let touch: [UInt8] = [0x05, 0x0D, 0x09, 0x04, 0xA1, 0x01, 0x85, 0x01] + finger + finger + [
        0x09, 0x54, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x02, // Contact count
        0xC0,
    ]
    let config: [UInt8] = [
        0x05, 0x0D, 0x09, 0x0E, 0xA1, 0x01, 0x85, 0x03, 0x09, 0x22, 0xA1, 0x02,
        0x09, 0x52, 0x15, 0x00, 0x25, 0x0A, 0x75, 0x08, 0x95, 0x01, 0xB1, 0x02, // Device mode
        0xC0, 0xC0,
    ]
    let pen: [UInt8] = [
        0x05, 0x0D, 0x09, 0x02, 0xA1, 0x01, 0x85, 0x04, 0x09, 0x20, 0xA1, 0x00,
        0x09, 0x42, 0x09, 0x44, 0x09, 0x45, 0x09, 0x3C, 0x09, 0x32, // tip, barrel, eraser, invert, in range
        0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x05, 0x81, 0x02,
        0x95, 0x03, 0x81, 0x03,
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x26, 0xFF, 0x7F, 0x75, 0x10, 0x95, 0x02, 0x81, 0x02,
        0x05, 0x0D, 0x09, 0x30, 0x26, 0xFF, 0x0F, 0x75, 0x10, 0x95, 0x01, 0x81, 0x02, // pressure
        0x09, 0x3D, 0x09, 0x3E, 0x16, 0xD8, 0xDC, 0x26, 0x28, 0x23, 0x75, 0x10, 0x95, 0x02, 0x81, 0x02, // tilt
        0xC0, 0xC0,
    ]
    return touch + config + pen
}()

func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }

func fingerBytes(tip: Bool, id: Int, x: Int, y: Int) -> [UInt8] {
    [tip ? 0x03 : 0x02, UInt8(id)] + le16(x) + le16(y)
}

@Suite struct DescriptorTests {
    @Test func parsesFieldPositions() {
        let d = HIDDescriptor(bytes: sampleDescriptor)
        #expect(d.usesReportIDs)
        #expect(d.payloadSize(.input, id: 1) == 13)
        #expect(d.payloadSize(.input, id: 4) == 11)
        let xs = d.fields.filter { $0.reportID == 1 && $0.usagePage == Usage.genericDesktop && $0.usage == Usage.x }
        #expect(xs.map(\.bitOffset) == [16, 64])
        #expect(xs.first?.logicalMax == 4095)
        let tilt = d.fields.first { $0.usage == Usage.xTilt }
        #expect(tilt?.logicalMin == -9000 && tilt?.logicalMax == 9000)
    }

    @Test func requestsMultitouchDeviceMode() {
        let decoder = DigitizerDecoder(descriptor: HIDDescriptor(bytes: sampleDescriptor))
        let writes = decoder.inputModeFeatureWrites()
        #expect(writes.map(\.reportID) == [3])
        #expect(writes.first?.values.map(\.1) == [3])
    }

    @Test func writesFieldBits() {
        let d = HIDDescriptor(bytes: sampleDescriptor)
        let x = d.fields.first { $0.reportID == 1 && $0.usage == Usage.x && $0.usagePage == Usage.genericDesktop }!
        var payload = [UInt8](repeating: 0xFF, count: 13)
        x.write(0x0123, into: &payload)
        #expect(Array(payload[2...3]) == [0x23, 0x01])
        #expect(x.value(in: payload) == 0x0123)
    }
}

@Suite struct DecoderTests {
    @Test func decodesTwoFingers() {
        let decoder = DigitizerDecoder(descriptor: HIDDescriptor(bytes: sampleDescriptor))
        let payload = fingerBytes(tip: true, id: 4, x: 0, y: 4095) + fingerBytes(tip: false, id: 7, x: 4095, y: 0) + [2]
        let events = decoder.decode(reportID: 1, payload: payload)
        #expect(events == [.touchFrame([
            TouchContact(id: 4, x: 0, y: 1, touching: true),
            TouchContact(id: 7, x: 1, y: 0, touching: false),
        ])])
    }

    @Test func assemblesHybridFrames() {
        let decoder = DigitizerDecoder(descriptor: HIDDescriptor(bytes: sampleDescriptor))
        let first = fingerBytes(tip: true, id: 1, x: 0, y: 0) + fingerBytes(tip: true, id: 2, x: 0, y: 0) + [3]
        let second = fingerBytes(tip: true, id: 3, x: 0, y: 0) + fingerBytes(tip: false, id: 0, x: 0, y: 0) + [0]
        #expect(decoder.decode(reportID: 1, payload: first).isEmpty)
        guard case let .touchFrame(contacts) = decoder.decode(reportID: 1, payload: second).first else {
            Issue.record("expected a frame"); return
        }
        #expect(contacts.map(\.id) == [1, 2, 3])
    }

    @Test func treatsLowConfidenceAsLifted() {
        let decoder = DigitizerDecoder(descriptor: HIDDescriptor(bytes: sampleDescriptor))
        var palm = fingerBytes(tip: true, id: 1, x: 10, y: 10)
        palm[0] = 0x01 // tip without confidence
        let payload = palm + fingerBytes(tip: false, id: 0, x: 0, y: 0) + [1]
        guard case let .touchFrame(contacts) = decoder.decode(reportID: 1, payload: payload).first else {
            Issue.record("expected a frame"); return
        }
        #expect(contacts.first?.touching == false)
    }

    @Test func decodesPen() {
        let decoder = DigitizerDecoder(descriptor: HIDDescriptor(bytes: sampleDescriptor))
        #expect(decoder.hasPen && decoder.hasTouch)
        // tip + eraser + in range
        let payload: [UInt8] = [0b10101] + le16(32767) + le16(0) + le16(4095) + le16(-4500 & 0xFFFF) + le16(9000)
        guard case let .pen(p) = decoder.decode(reportID: 4, payload: payload).first else {
            Issue.record("expected a pen sample"); return
        }
        #expect(p.tip && p.inRange && p.eraser && !p.barrel)
        #expect(p.x == 1 && p.y == 0 && p.pressure == 1)
        #expect(p.tiltX == -0.5 && p.tiltY == 1)
    }
}

final class RecordingSink: PointerSink {
    var log: [String] = []
    func move(to point: Point, pen: PenState?) { log.append("move \(Int(point.x)),\(Int(point.y))") }
    func button(_ button: MouseButton, down: Bool, at point: Point, clickCount: Int, pen: PenState?) {
        log.append("\(button) \(down ? "down" : "up") \(Int(point.x)),\(Int(point.y)) x\(clickCount)")
    }
    func drag(_ button: MouseButton, to point: Point, pen: PenState?) { log.append("drag \(Int(point.x)),\(Int(point.y))") }
    func scroll(dx: Double, dy: Double, phase: ScrollPhase?, momentum: MomentumPhase) {
        log.append("scroll \(Int(dx)),\(Int(dy)) \(phase.map { "\($0)" } ?? "-") \(momentum)")
    }
    func penProximity(entering: Bool, eraser: Bool) { log.append(entering ? "proximity in" : "proximity out") }
}

func touches(_ points: (Int, Double, Double)...) -> [(id: Int, point: Point)] {
    points.map { (id: $0.0, point: Point(x: $0.1, y: $0.2)) }
}

@Suite struct GestureTests {
    @Test func tapClicksAndDoubleTapDoubleClicks() {
        let sink = RecordingSink()
        let engine = TouchGestureEngine(sink: sink)
        engine.process(touches((1, 100, 100)), now: 0)
        engine.process([], now: 0.1)
        engine.process(touches((2, 103, 101)), now: 0.25)
        engine.process([], now: 0.3)
        #expect(sink.log == [
            "move 100,100", "left down 100,100 x1", "left up 100,100 x1",
            "move 103,101", "left down 103,101 x2", "left up 103,101 x2",
        ])
    }

    @Test func dragsAfterSlop() {
        let sink = RecordingSink()
        let engine = TouchGestureEngine(sink: sink)
        engine.process(touches((1, 100, 100)), now: 0)
        engine.process(touches((1, 105, 100)), now: 0.05) // within slop
        engine.process(touches((1, 150, 100)), now: 0.1)
        engine.process(touches((1, 200, 100)), now: 0.15)
        engine.process([], now: 0.2)
        #expect(sink.log == ["move 100,100", "left down 100,100 x1", "drag 150,100", "drag 200,100", "left up 200,100 x1"])
    }

    @Test func longPressRightClicks() {
        let sink = RecordingSink()
        let engine = TouchGestureEngine(sink: sink)
        engine.process(touches((1, 50, 50)), now: 0)
        #expect(engine.needsTick)
        engine.tick(now: 0.3)
        engine.tick(now: 0.7)
        engine.process(touches((1, 80, 50)), now: 0.8) // ignored after the long press
        engine.process([], now: 0.9)
        #expect(sink.log == ["move 50,50", "right down 50,50 x1", "right up 50,50 x1"])
    }

    @Test func twoFingersScroll() {
        let sink = RecordingSink()
        var settings = GestureSettings()
        settings.momentumScrolling = false
        let engine = TouchGestureEngine(sink: sink, settings: settings)
        engine.process(touches((1, 100, 100)), now: 0)
        engine.process(touches((1, 100, 100), (2, 200, 100)), now: 0.05)
        engine.process(touches((1, 100, 130), (2, 200, 130)), now: 0.1)
        engine.process(touches((1, 100, 140), (2, 200, 140)), now: 0.15)
        engine.process([], now: 0.2)
        #expect(sink.log == [
            "move 100,100", "move 150,100",
            "scroll 0,30 began none", "scroll 0,10 changed none", "scroll 0,0 ended none",
        ])
    }

    @Test func twoFingerTapRightClicks() {
        let sink = RecordingSink()
        let engine = TouchGestureEngine(sink: sink)
        engine.process(touches((1, 100, 100), (2, 120, 100)), now: 0)
        engine.process([], now: 0.1)
        #expect(sink.log == ["move 110,100", "right down 110,100 x1", "right up 110,100 x1"])
    }

    @Test func penStrokeWithBarrelRightClicks() {
        let sink = RecordingSink()
        let pen = PenTracker(sink: sink)
        func sample(_ range: Bool, _ tip: Bool, barrel: Bool = false) -> PenSample {
            PenSample(x: 0, y: 0, inRange: range, tip: tip, barrel: barrel, pressure: tip ? 0.5 : 0)
        }
        pen.process(sample(true, false), at: Point(x: 10, y: 10), now: 0)
        pen.process(sample(true, true, barrel: true), at: Point(x: 10, y: 10), now: 0.1)
        pen.process(sample(true, true, barrel: true), at: Point(x: 12, y: 10), now: 0.2)
        pen.process(sample(true, false), at: Point(x: 12, y: 10), now: 0.3)
        pen.process(sample(false, false), at: Point(x: 12, y: 10), now: 0.4)
        #expect(sink.log == [
            "proximity in", "move 10,10", "right down 10,10 x1", "drag 12,10", "right up 12,10 x1",
            "proximity out",
        ])
    }
}
