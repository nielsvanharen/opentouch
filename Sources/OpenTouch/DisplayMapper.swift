import AppKit
import OpenTouchCore

/// Identifies a display across reconnects and reboots.
struct DisplayIdentity: Codable, Equatable {
    var vendor: UInt32
    var model: UInt32
    var serial: UInt32

    init(_ id: CGDirectDisplayID) {
        vendor = CGDisplayVendorNumber(id)
        model = CGDisplayModelNumber(id)
        serial = CGDisplaySerialNumber(id)
    }
}

/// Maps normalized panel coordinates onto the display the touch panel is glued to.
final class DisplayMapper {
    private static let defaultsKey = "targetDisplay"
    // Panel names that are known touch monitors, used when nothing has been chosen.
    private static let knownTouchDisplays = ["M14t", "M15t"]

    private var cachedBounds: CGRect?
    private var cachedRotation = 0.0

    var chosen: DisplayIdentity? {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey) else { return nil }
            return try? JSONDecoder().decode(DisplayIdentity.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: Self.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
            }
            refresh()
        }
    }

    init() {
        refresh()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.refresh() }
    }

    static func screens() -> [(id: CGDirectDisplayID, name: String)] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            return (CGDirectDisplayID(number.uint32Value), screen.localizedName)
        }
    }

    /// The display touches go to: the user's choice, a known touch monitor, or the only external display.
    func targetDisplay() -> CGDirectDisplayID? {
        let screens = Self.screens()
        if let chosen, let match = screens.first(where: { DisplayIdentity($0.id) == chosen }) {
            return match.id
        }
        if let known = screens.first(where: { s in Self.knownTouchDisplays.contains { s.name.contains($0) } }) {
            return known.id
        }
        let external = screens.filter { CGDisplayIsBuiltin($0.id) == 0 }
        if external.count == 1 { return external[0].id }
        return screens.first?.id
    }

    func refresh() {
        guard let id = targetDisplay() else {
            cachedBounds = nil
            return
        }
        cachedBounds = CGDisplayBounds(id)
        cachedRotation = CGDisplayRotation(id)
    }

    /// Converts panel coordinates (0...1, panel's own orientation) into global screen points.
    func map(x: Double, y: Double) -> Point? {
        guard let bounds = cachedBounds else { return nil }
        // The panel rotates together with the display, so undo the rotation macOS applies.
        let (u, v): (Double, Double)
        switch Int(cachedRotation.rounded()) {
        case 90: (u, v) = (1 - y, x)
        case 180: (u, v) = (1 - x, 1 - y)
        case 270: (u, v) = (y, 1 - x)
        default: (u, v) = (x, y)
        }
        // Keep the last pixel on the display; maxX/maxY belong to the neighbour.
        return Point(x: bounds.minX + min(u * bounds.width, bounds.width - 1),
                     y: bounds.minY + min(v * bounds.height, bounds.height - 1))
    }
}
