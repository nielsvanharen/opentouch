import Foundation
import IOKit.hid
import OpenTouchCore

/// One connected digitizer interface (a USB touch screen often exposes several).
final class DigitizerDevice {
    let device: IOHIDDevice
    let decoder: DigitizerDecoder
    let name: String
    let reportDescriptor: [UInt8]
    fileprivate(set) var seized = false
    fileprivate var buffer: UnsafeMutablePointer<UInt8>
    fileprivate let bufferSize: Int
    fileprivate weak var service: HIDService?

    init?(device: IOHIDDevice) {
        guard let data = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data else { return nil }
        self.device = device
        reportDescriptor = [UInt8](data)
        decoder = DigitizerDecoder(descriptor: HIDDescriptor(bytes: reportDescriptor))
        name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "Unknown digitizer"
        let reported = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? 0
        bufferSize = max(reported, 64)
        buffer = .allocate(capacity: bufferSize)
    }

    deinit { buffer.deallocate() }

    /// Stable for as long as the device stays connected; tells apart interfaces with the same name.
    var registryID: UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id)
        return id
    }

    var vendorID: Int { (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) ?? 0 }
    var productID: Int { (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0 }

    /// Puts Windows-style touch screens into multi-touch mode. Many panels only send
    /// single-touch mouse reports until the host writes the Device Mode feature.
    func enableMultitouchMode() {
        let descriptor = decoder.descriptor
        for write in decoder.inputModeFeatureWrites() {
            let prefix = descriptor.usesReportIDs ? 1 : 0
            var report = [UInt8](repeating: 0, count: descriptor.payloadSize(.feature, id: write.reportID) + prefix)
            if prefix == 1 { report[0] = write.reportID }
            var length = report.count
            // Start from the current values so we only change the fields we care about.
            _ = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(write.reportID), &report, &length)
            var payload = Array(report.dropFirst(prefix))
            for (field, value) in write.values { field.write(value, into: &payload) }
            report = (prefix == 1 ? [write.reportID] : []) + payload
            let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(write.reportID),
                                              report, report.count)
            Log.info("Set input mode on \(name) (feature report \(write.reportID)): \(result == kIOReturnSuccess ? "ok" : String(format: "0x%08x", result))")
        }
    }

    fileprivate func handle(reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: Int) {
        var payload = Array(UnsafeBufferPointer(start: report, count: length))
        if decoder.descriptor.usesReportIDs, !payload.isEmpty { payload.removeFirst() }
        service?.deliver(reportID: UInt8(truncatingIfNeeded: reportID), payload: payload, from: self)
    }
}

/// Finds touch screens and pens, opens them and forwards decoded events.
final class HIDService {
    var onEvent: ((DigitizerEvent, DigitizerDevice) -> Void)?
    var onRawReport: ((UInt8, [UInt8], DigitizerDevice) -> Void)?
    var onDevicesChanged: (() -> Void)?
    /// Called when opening a device failed for lack of the Input Monitoring permission.
    var onPermissionDenied: (() -> Void)?

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private(set) var devices: [DigitizerDevice] = []
    private let seize: Bool

    /// - Parameter seize: take exclusive access so macOS' own driver does not also act on the reports.
    init(seize: Bool) {
        self.seize = seize
    }

    func start() {
        let matches: [[String: Int]] = [
            [kIOHIDDeviceUsagePageKey: Int(Usage.digitizer), kIOHIDDeviceUsageKey: Int(Usage.touchScreen)],
            [kIOHIDDeviceUsagePageKey: Int(Usage.digitizer), kIOHIDDeviceUsageKey: Int(Usage.pen)],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            Unmanaged<HIDService>.fromOpaque(context!).takeUnretainedValue().attach(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            Unmanaged<HIDService>.fromOpaque(context!).takeUnretainedValue().detach(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        // Devices are opened individually so we can choose to seize each one.
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    fileprivate func deliver(reportID: UInt8, payload: [UInt8], from device: DigitizerDevice) {
        onRawReport?(reportID, payload, device)
        for event in device.decoder.decode(reportID: reportID, payload: payload) {
            onEvent?(event, device)
        }
    }

    private func attach(_ hid: IOHIDDevice) {
        // A panel with both a touch screen and a pen collection matches both criteria and is
        // reported twice, as separate IOHIDDevice objects for the same service.
        guard let device = DigitizerDevice(device: hid),
              !devices.contains(where: { $0.registryID == device.registryID }) else { return }
        device.service = self

        var result = kIOReturnError
        if seize {
            result = IOHIDDeviceOpen(hid, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            device.seized = result == kIOReturnSuccess
        }
        if result != kIOReturnSuccess {
            result = IOHIDDeviceOpen(hid, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        guard result == kIOReturnSuccess else {
            Log.info("Could not open \(device.name): " + String(format: "0x%08x", result))
            if result == kIOReturnNotPermitted { onPermissionDenied?() }
            return
        }

        IOHIDDeviceRegisterInputReportCallback(hid, device.buffer, device.bufferSize, { context, _, _, _, reportID, report, length in
            Unmanaged<DigitizerDevice>.fromOpaque(context!).takeUnretainedValue()
                .handle(reportID: reportID, report: report, length: length)
        }, Unmanaged.passUnretained(device).toOpaque())

        device.enableMultitouchMode()
        devices.append(device)
        Log.info("Attached \(device.name) [\(String(format: "%04X:%04X", device.vendorID, device.productID))]"
                 + " touch=\(device.decoder.hasTouch) pen=\(device.decoder.hasPen) seized=\(device.seized)")
        onDevicesChanged?()
    }

    private func detach(_ hid: IOHIDDevice) {
        var serviceID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(hid), &serviceID)
        guard let index = devices.firstIndex(where: { $0.device == hid || $0.registryID == serviceID }) else { return }
        IOHIDDeviceClose(hid, IOOptionBits(kIOHIDOptionsTypeNone))
        Log.info("Detached \(devices[index].name)")
        devices.remove(at: index)
        onDevicesChanged?()
    }
}

enum Log {
    static func info(_ message: String) {
        FileHandle.standardError.write(Data(("[OpenTouch] " + message + "\n").utf8))
    }
}
