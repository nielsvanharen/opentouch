// Turns raw digitizer input reports into touch frames and pen samples.
//
// Follows the Windows "precision touch screen" / HID digitizer conventions that
// practically every modern touch screen and active pen implements.

public enum Usage {
    public static let genericDesktop: UInt16 = 0x01
    public static let digitizer: UInt16 = 0x0D

    public static let x: UInt16 = 0x30
    public static let y: UInt16 = 0x31

    public static let pen: UInt16 = 0x02
    public static let touchScreen: UInt16 = 0x04
    public static let stylus: UInt16 = 0x20
    public static let finger: UInt16 = 0x22
    public static let tipPressure: UInt16 = 0x30
    public static let inRange: UInt16 = 0x32
    public static let invert: UInt16 = 0x3C
    public static let xTilt: UInt16 = 0x3D
    public static let yTilt: UInt16 = 0x3E
    public static let tipSwitch: UInt16 = 0x42
    public static let barrelSwitch: UInt16 = 0x44
    public static let eraser: UInt16 = 0x45
    public static let confidence: UInt16 = 0x47
    public static let contactID: UInt16 = 0x51
    public static let deviceMode: UInt16 = 0x52
    public static let contactCount: UInt16 = 0x54
    public static let surfaceSwitch: UInt16 = 0x57
    public static let buttonSwitch: UInt16 = 0x58
}

/// A finger on the screen. Coordinates are normalized to 0...1 in panel space.
public struct TouchContact: Equatable, Sendable {
    public var id: Int
    public var x: Double
    public var y: Double
    public var touching: Bool

    public init(id: Int, x: Double, y: Double, touching: Bool) {
        self.id = id; self.x = x; self.y = y; self.touching = touching
    }
}

public struct PenSample: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var inRange: Bool
    public var tip: Bool
    public var barrel: Bool
    public var eraser: Bool
    /// 0...1
    public var pressure: Double
    /// -1...1, nil when the pen does not report tilt.
    public var tiltX: Double?
    public var tiltY: Double?

    public init(x: Double, y: Double, inRange: Bool, tip: Bool, barrel: Bool = false, eraser: Bool = false,
                pressure: Double, tiltX: Double? = nil, tiltY: Double? = nil) {
        self.x = x; self.y = y; self.inRange = inRange; self.tip = tip; self.barrel = barrel
        self.eraser = eraser; self.pressure = pressure; self.tiltX = tiltX; self.tiltY = tiltY
    }
}

public enum DigitizerEvent: Equatable, Sendable {
    /// A complete frame: every contact the device currently reports.
    case touchFrame([TouchContact])
    case pen(PenSample)
}

/// One finger or stylus collection inside a report.
private struct ContactLayout {
    var x: HIDField?
    var y: HIDField?
    var tip: HIDField?
    var inRange: HIDField?
    var confidence: HIDField?
    var contactID: HIDField?
    var pressure: HIDField?
    var barrel: HIDField?
    var invert: HIDField?
    var eraser: HIDField?
    var xTilt: HIDField?
    var yTilt: HIDField?
}

private struct ReportLayout {
    var isPen: Bool
    var contacts: [ContactLayout]
    var contactCount: HIDField?
}

public final class DigitizerDecoder {
    public let descriptor: HIDDescriptor
    private var layouts: [UInt8: ReportLayout] = [:]

    // Hybrid-mode assembly: a frame with more contacts than fit in one report is
    // split across several reports; only the first carries the real contact count.
    private var expectedContacts = 0
    private var pendingContacts: [TouchContact] = []

    public init(descriptor: HIDDescriptor) {
        self.descriptor = descriptor
        buildLayouts()
    }

    public var hasTouch: Bool { layouts.values.contains { !$0.isPen } }
    public var hasPen: Bool { layouts.values.contains { $0.isPen } }

    /// Feature fields that put a Windows-style touch screen into multi-touch mode.
    /// Returns (reportID, [(field, value)]) for each feature report to send.
    public func inputModeFeatureWrites() -> [(reportID: UInt8, values: [(HIDField, Int32)])] {
        var byReport: [UInt8: [(HIDField, Int32)]] = [:]
        for f in descriptor.fields where f.reportType == .feature && f.usagePage == Usage.digitizer {
            switch f.usage {
            case Usage.deviceMode: byReport[f.reportID, default: []].append((f, 3)) // multi-touch device mode
            case Usage.surfaceSwitch, Usage.buttonSwitch: byReport[f.reportID, default: []].append((f, 1))
            default: break
            }
        }
        return byReport.map { ($0.key, $0.value) }.sorted { $0.reportID < $1.reportID }
    }

    /// Decodes one input report. `payload` must not include the report ID byte.
    public func decode(reportID: UInt8, payload: [UInt8]) -> [DigitizerEvent] {
        guard let layout = layouts[reportID] else { return [] }
        if layout.isPen {
            return layout.contacts.compactMap { pen(from: $0, payload: payload) }.map(DigitizerEvent.pen)
        }

        var contacts: [TouchContact] = []
        for (slot, c) in layout.contacts.enumerated() {
            guard let x = c.x?.normalized(in: payload), let y = c.y?.normalized(in: payload) else { continue }
            var tip = c.tip.flatMap { $0.value(in: payload) }.map { $0 != 0 } ?? true
            // Confidence 0 means the panel thinks this is a palm, not a finger.
            if let confident = c.confidence?.value(in: payload), confident == 0 { tip = false }
            let id = c.contactID.flatMap { $0.value(in: payload) }.map(Int.init) ?? slot
            contacts.append(TouchContact(id: id, x: x, y: y, touching: tip))
        }

        guard let countField = layout.contactCount, let count = countField.value(in: payload) else {
            // No contact count: each report is a full frame.
            return [.touchFrame(contacts)]
        }

        if count > 0 {
            expectedContacts = Int(count)
            pendingContacts = []
        }
        guard expectedContacts > 0 else { return [] }
        let remaining = expectedContacts - pendingContacts.count
        pendingContacts.append(contentsOf: contacts.prefix(remaining))
        guard pendingContacts.count >= expectedContacts else { return [] }

        let frame = pendingContacts
        expectedContacts = 0
        pendingContacts = []
        return [.touchFrame(frame)]
    }

    private func pen(from c: ContactLayout, payload: [UInt8]) -> PenSample? {
        guard let x = c.x?.normalized(in: payload), let y = c.y?.normalized(in: payload) else { return nil }
        func flag(_ f: HIDField?) -> Bool { f.flatMap { $0.value(in: payload) }.map { $0 != 0 } ?? false }
        func tilt(_ f: HIDField?) -> Double? {
            guard let f, let v = f.value(in: payload) else { return nil }
            let range = Double(max(abs(f.logicalMin), abs(f.logicalMax)))
            return range > 0 ? Double(v) / range : nil
        }
        let tip = flag(c.tip)
        let inRange = c.inRange == nil ? true : flag(c.inRange)
        var pressure = c.pressure?.normalized(in: payload) ?? (tip ? 1 : 0)
        if !tip { pressure = 0 }
        return PenSample(x: x, y: y, inRange: inRange || tip, tip: tip, barrel: flag(c.barrel),
                         eraser: flag(c.invert) || flag(c.eraser), pressure: pressure,
                         tiltX: tilt(c.xTilt), tiltY: tilt(c.yTilt))
    }

    private func buildLayouts() {
        let inputs = descriptor.fields.filter { $0.reportType == .input }
        let reportIDs = Set(inputs.map(\.reportID))

        for id in reportIDs {
            let fields = inputs.filter { $0.reportID == id }
            // Group fields per innermost collection, keeping descriptor order.
            var order: [Int] = []
            var groups: [Int: ContactLayout] = [:]
            var contactCount: HIDField?
            var isPen = false
            var isDigitizer = false

            for f in fields {
                guard f.collection >= 0 else { continue }
                if let app = descriptor.applicationCollection(of: f.collection), app.usagePage == Usage.digitizer {
                    isDigitizer = true
                    if app.usage == Usage.pen { isPen = true }
                }
                if f.usagePage == Usage.digitizer && f.usage == Usage.contactCount {
                    contactCount = f
                    continue
                }
                if groups[f.collection] == nil {
                    groups[f.collection] = ContactLayout()
                    order.append(f.collection)
                }
                switch (f.usagePage, f.usage) {
                case (Usage.genericDesktop, Usage.x): groups[f.collection]!.x = groups[f.collection]!.x ?? f
                case (Usage.genericDesktop, Usage.y): groups[f.collection]!.y = groups[f.collection]!.y ?? f
                case (Usage.digitizer, Usage.tipSwitch): groups[f.collection]!.tip = f
                case (Usage.digitizer, Usage.inRange): groups[f.collection]!.inRange = f
                case (Usage.digitizer, Usage.confidence): groups[f.collection]!.confidence = f
                case (Usage.digitizer, Usage.contactID): groups[f.collection]!.contactID = f
                case (Usage.digitizer, Usage.tipPressure): groups[f.collection]!.pressure = f
                case (Usage.digitizer, Usage.barrelSwitch): groups[f.collection]!.barrel = f
                case (Usage.digitizer, Usage.invert): groups[f.collection]!.invert = f
                case (Usage.digitizer, Usage.eraser): groups[f.collection]!.eraser = f
                case (Usage.digitizer, Usage.xTilt): groups[f.collection]!.xTilt = f
                case (Usage.digitizer, Usage.yTilt): groups[f.collection]!.yTilt = f
                default: break
                }
            }

            let contacts = order.compactMap { groups[$0] }.filter { $0.x != nil && $0.y != nil }
            guard isDigitizer, !contacts.isEmpty else { continue }
            layouts[id] = ReportLayout(isPen: isPen, contacts: contacts, contactCount: isPen ? nil : contactCount)
        }
    }
}
