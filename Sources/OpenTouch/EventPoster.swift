import CoreGraphics
import OpenTouchCore

/// Turns gestures into synthetic mouse, scroll and tablet events.
/// Posting requires the Accessibility permission.
final class EventPoster: PointerSink {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var scrollRemainder = (x: 0.0, y: 0.0)

    // Identifiers that tie tablet point events to their proximity events.
    private static let tabletDeviceID: Int64 = 0x4F54
    private static let scrollPhaseField = CGEventField(rawValue: 99)!     // kCGScrollWheelEventScrollPhase
    private static let momentumPhaseField = CGEventField(rawValue: 123)! // kCGScrollWheelEventMomentumPhase

    func move(to point: Point, pen: PenState?) {
        post(.mouseMoved, at: point, button: .left, clickCount: 0, pen: pen)
    }

    func button(_ button: MouseButton, down: Bool, at point: Point, clickCount: Int, pen: PenState?) {
        let type: CGEventType
        switch (button, down) {
        case (.left, true): type = .leftMouseDown
        case (.left, false): type = .leftMouseUp
        case (.right, true): type = .rightMouseDown
        case (.right, false): type = .rightMouseUp
        }
        post(type, at: point, button: button == .left ? .left : .right, clickCount: clickCount, pen: pen)
    }

    func drag(_ button: MouseButton, to point: Point, pen: PenState?) {
        post(button == .left ? .leftMouseDragged : .rightMouseDragged, at: point,
             button: button == .left ? .left : .right, clickCount: 1, pen: pen)
    }

    func scroll(dx: Double, dy: Double, phase: ScrollPhase?, momentum: MomentumPhase) {
        // Pixel scroll events take integers; carry the fractions over so slow scrolls still move.
        let x = dx + scrollRemainder.x
        let y = dy + scrollRemainder.y
        let wheelX = x.rounded(.towardZero)
        let wheelY = y.rounded(.towardZero)
        scrollRemainder = (x - wheelX, y - wheelY)
        if phase == .began || phase == .ended { scrollRemainder = (0, 0) }

        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(wheelY), wheel2: Int32(wheelX), wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        switch phase {
        case .began: event.setIntegerValueField(Self.scrollPhaseField, value: 1)
        case .changed: event.setIntegerValueField(Self.scrollPhaseField, value: 2)
        case .ended: event.setIntegerValueField(Self.scrollPhaseField, value: 4)
        case nil: event.setIntegerValueField(Self.scrollPhaseField, value: 0)
        }
        switch momentum {
        case .none: break
        case .began: event.setIntegerValueField(Self.momentumPhaseField, value: 1)
        case .changed: event.setIntegerValueField(Self.momentumPhaseField, value: 2)
        case .ended: event.setIntegerValueField(Self.momentumPhaseField, value: 3)
        }
        event.post(tap: .cghidEventTap)
    }

    func penProximity(entering: Bool, eraser: Bool) {
        guard let event = CGEvent(source: source) else { return }
        event.type = .tabletProximity
        event.location = CGEvent(source: nil)?.location ?? .zero
        event.setIntegerValueField(.tabletProximityEventVendorID, value: 0x2D1F)
        event.setIntegerValueField(.tabletProximityEventTabletID, value: 1)
        event.setIntegerValueField(.tabletProximityEventPointerID, value: 1)
        event.setIntegerValueField(.tabletProximityEventDeviceID, value: Self.tabletDeviceID)
        event.setIntegerValueField(.tabletProximityEventSystemTabletID, value: 1)
        event.setIntegerValueField(.tabletProximityEventVendorPointerSerialNumber, value: 1)
        event.setIntegerValueField(.tabletProximityEventVendorUniqueID, value: 1)
        // Device ID, absolute X/Y, buttons, tilt X/Y and pressure.
        event.setIntegerValueField(.tabletProximityEventCapabilityMask, value: 0x05C7)
        event.setIntegerValueField(.tabletProximityEventPointerType, value: eraser ? 3 : 1)
        event.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
        event.post(tap: .cghidEventTap)
    }

    private func post(_ type: CGEventType, at point: Point, button: CGMouseButton, clickCount: Int, pen: PenState?) {
        let location = CGPoint(x: point.x, y: point.y)
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: location, mouseButton: button) else { return }
        if clickCount > 0 {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        }
        if let pen {
            event.setIntegerValueField(.mouseEventSubtype, value: 1) // kCGEventMouseSubtypeTabletPoint
            event.setDoubleValueField(.mouseEventPressure, value: pen.pressure)
            event.setIntegerValueField(.tabletEventPointX, value: Int64(point.x.rounded()))
            event.setIntegerValueField(.tabletEventPointY, value: Int64(point.y.rounded()))
            event.setDoubleValueField(.tabletEventPointPressure, value: pen.pressure)
            event.setDoubleValueField(.tabletEventTiltX, value: pen.tiltX)
            event.setDoubleValueField(.tabletEventTiltY, value: pen.tiltY)
            event.setIntegerValueField(.tabletEventDeviceID, value: Self.tabletDeviceID)
        }
        event.post(tap: .cghidEventTap)
    }
}
