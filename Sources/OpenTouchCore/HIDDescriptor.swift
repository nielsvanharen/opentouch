// A small USB HID report descriptor parser.
//
// It only needs to understand enough of the spec to locate the fields of
// digitizer reports (touch screens and pens): variable input/feature items,
// their bit position inside a report, their usage and logical range, and the
// collection they live in.

public enum HIDReportType: Sendable {
    case input, output, feature
}

public struct HIDCollection: Sendable {
    public let index: Int
    public let parent: Int?
    /// 0 = physical, 1 = application, 2 = logical, ...
    public let kind: UInt8
    public let usagePage: UInt16
    public let usage: UInt16
}

public struct HIDField: Sendable, CustomStringConvertible {
    public let reportType: HIDReportType
    public let reportID: UInt8
    /// Bit offset inside the report payload, i.e. *after* the report ID byte.
    public let bitOffset: Int
    public let bitSize: Int
    public let usagePage: UInt16
    public let usage: UInt16
    public let logicalMin: Int32
    public let logicalMax: Int32
    public let isConstant: Bool
    /// Index into `HIDDescriptor.collections` of the innermost enclosing collection.
    public let collection: Int

    public var isSigned: Bool { logicalMin < 0 }

    public var description: String {
        String(format: "report %u  bits %4d+%-2d  page 0x%02X usage 0x%02X  range %d...%d  coll %d",
               reportID, bitOffset, bitSize, usagePage, usage, logicalMin, logicalMax, collection)
    }

    /// Extracts the raw value of this field from a report payload (report ID byte stripped).
    public func value(in payload: [UInt8]) -> Int32? {
        guard bitSize > 0, bitSize <= 32, bitOffset + bitSize <= payload.count * 8 else { return nil }
        var raw: UInt32 = 0
        for i in 0..<bitSize {
            let bit = bitOffset + i
            if payload[bit >> 3] & (1 << UInt8(bit & 7)) != 0 {
                raw |= 1 << UInt32(i)
            }
        }
        if isSigned, bitSize < 32, raw & (1 << UInt32(bitSize - 1)) != 0 {
            raw |= ~((1 << UInt32(bitSize)) - 1)
        }
        return Int32(bitPattern: raw)
    }

    /// Writes `value` into this field's bits of a report payload (report ID byte stripped).
    public func write(_ value: Int32, into payload: inout [UInt8]) {
        guard bitSize > 0, bitSize <= 32, bitOffset + bitSize <= payload.count * 8 else { return }
        let raw = UInt32(bitPattern: value)
        for i in 0..<bitSize {
            let bit = bitOffset + i
            let mask = UInt8(1 << UInt8(bit & 7))
            if raw & (1 << UInt32(i)) != 0 {
                payload[bit >> 3] |= mask
            } else {
                payload[bit >> 3] &= ~mask
            }
        }
    }

    /// Value scaled into 0...1 using the logical range.
    public func normalized(in payload: [UInt8]) -> Double? {
        guard let v = value(in: payload), logicalMax > logicalMin else { return nil }
        let n = Double(v - logicalMin) / Double(Int64(logicalMax) - Int64(logicalMin))
        return min(max(n, 0), 1)
    }
}

public struct HIDDescriptor: Sendable {
    public private(set) var collections: [HIDCollection] = []
    public private(set) var fields: [HIDField] = []
    /// Payload size in bytes (without report ID byte) per (type, reportID).
    public private(set) var reportSizes: [String: Int] = [:]
    public private(set) var usesReportIDs = false

    public init(bytes: [UInt8]) {
        parse(bytes)
    }

    public func payloadSize(_ type: HIDReportType, id: UInt8) -> Int {
        reportSizes[Self.key(type, id)] ?? 0
    }

    /// Walks up from `collection` and returns the first application collection.
    public func applicationCollection(of collection: Int) -> HIDCollection? {
        var current: Int? = collection
        while let c = current {
            let coll = collections[c]
            if coll.kind == 1 { return coll }
            current = coll.parent
        }
        return nil
    }

    private static func key(_ type: HIDReportType, _ id: UInt8) -> String { "\(type)-\(id)" }

    private struct GlobalState {
        var usagePage: UInt16 = 0
        var logicalMin: Int32 = 0
        var logicalMax: Int32 = 0
        var logicalMaxRaw: UInt32 = 0
        var reportSize = 0
        var reportID: UInt8 = 0
        var reportCount = 0
    }

    private mutating func parse(_ bytes: [UInt8]) {
        var global = GlobalState()
        var globalStack: [GlobalState] = []
        // Local state: usages carry their own page when given as 32-bit values.
        var usages: [(page: UInt16?, usage: UInt16)] = []
        var usageMin: (page: UInt16?, usage: UInt16)?
        var usageMax: UInt16?
        var collectionStack: [Int] = []
        var bitPositions: [String: Int] = [:]

        func resetLocals() {
            usages = []
            usageMin = nil
            usageMax = nil
        }

        var i = 0
        while i < bytes.count {
            let prefix = bytes[i]
            if prefix == 0xFE { // long item: size, tag, data
                guard i + 1 < bytes.count else { break }
                i += 3 + Int(bytes[i + 1])
                continue
            }
            let sizeCode = Int(prefix & 0x03)
            let size = sizeCode == 3 ? 4 : sizeCode
            let type = (prefix >> 2) & 0x03
            let tag = prefix >> 4
            guard i + size < bytes.count else { break }

            var unsigned: UInt32 = 0
            for b in 0..<size {
                unsigned |= UInt32(bytes[i + 1 + b]) << UInt32(8 * b)
            }
            let signed: Int32
            switch size {
            case 1: signed = Int32(Int8(bitPattern: UInt8(truncatingIfNeeded: unsigned)))
            case 2: signed = Int32(Int16(bitPattern: UInt16(truncatingIfNeeded: unsigned)))
            case 4: signed = Int32(bitPattern: unsigned)
            default: signed = 0
            }
            i += 1 + size

            switch type {
            case 0: // main
                switch tag {
                case 0x8, 0x9, 0xB: // input, output, feature
                    let reportType: HIDReportType = tag == 0x8 ? .input : (tag == 0x9 ? .output : .feature)
                    let flags = unsigned
                    let isConstant = flags & 0x01 != 0
                    let isVariable = flags & 0x02 != 0
                    let key = Self.key(reportType, global.reportID)
                    var position = bitPositions[key] ?? 0

                    // Logical max is often encoded unsigned (e.g. 0xFFFF in two bytes) while
                    // logical min is 0; only treat it as signed when min is negative.
                    var logicalMax = global.logicalMax
                    if global.logicalMin >= 0 && logicalMax < global.logicalMin {
                        logicalMax = Int32(bitPattern: global.logicalMaxRaw)
                    }

                    var resolved: [(page: UInt16, usage: UInt16)] = usages.map { ($0.page ?? global.usagePage, $0.usage) }
                    if resolved.isEmpty, let lo = usageMin, let hi = usageMax, hi >= lo.usage {
                        resolved = (lo.usage...hi).map { (lo.page ?? global.usagePage, $0) }
                    }

                    for n in 0..<global.reportCount {
                        if isVariable && !isConstant && !resolved.isEmpty {
                            let u = resolved[min(n, resolved.count - 1)]
                            fields.append(HIDField(
                                reportType: reportType, reportID: global.reportID,
                                bitOffset: position, bitSize: global.reportSize,
                                usagePage: u.page, usage: u.usage,
                                logicalMin: global.logicalMin, logicalMax: logicalMax,
                                isConstant: isConstant, collection: collectionStack.last ?? -1))
                        }
                        position += global.reportSize
                    }
                    bitPositions[key] = position
                    reportSizes[key] = (position + 7) / 8
                    resetLocals()
                case 0xA: // collection
                    let u = usages.first.map { ($0.page ?? global.usagePage, $0.usage) } ?? (global.usagePage, 0)
                    collections.append(HIDCollection(index: collections.count, parent: collectionStack.last,
                                                     kind: UInt8(truncatingIfNeeded: unsigned),
                                                     usagePage: u.0, usage: u.1))
                    collectionStack.append(collections.count - 1)
                    resetLocals()
                case 0xC: // end collection
                    _ = collectionStack.popLast()
                    resetLocals()
                default:
                    resetLocals()
                }
            case 1: // global
                switch tag {
                case 0x0: global.usagePage = UInt16(truncatingIfNeeded: unsigned)
                case 0x1: global.logicalMin = signed
                case 0x2:
                    global.logicalMax = signed
                    global.logicalMaxRaw = unsigned
                case 0x7: global.reportSize = Int(unsigned)
                case 0x8:
                    global.reportID = UInt8(truncatingIfNeeded: unsigned)
                    usesReportIDs = true
                case 0x9: global.reportCount = Int(unsigned)
                case 0xA: globalStack.append(global)
                case 0xB: if let g = globalStack.popLast() { global = g }
                default: break
                }
            case 2: // local
                let page: UInt16? = size == 4 ? UInt16(truncatingIfNeeded: unsigned >> 16) : nil
                let usage = UInt16(truncatingIfNeeded: unsigned)
                switch tag {
                case 0x0: usages.append((page, usage))
                case 0x1: usageMin = (page, usage)
                case 0x2: usageMax = usage
                default: break
                }
            default:
                break
            }
        }
    }
}
