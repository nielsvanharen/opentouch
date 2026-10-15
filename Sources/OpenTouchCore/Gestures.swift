// Gesture recognition for fingers and pen, independent of how events are posted.
//
// All coordinates here are screen points in global display space (top-left
// origin, like CGEvent). Time is in seconds; callers pass a monotonic clock.

import Foundation

public struct Point: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }

    func distance(to other: Point) -> Double {
        ((x - other.x) * (x - other.x) + (y - other.y) * (y - other.y)).squareRoot()
    }
}

public enum MouseButton: Sendable { case left, right }

public enum ScrollPhase: Sendable { case began, changed, ended }
public enum MomentumPhase: Sendable { case none, began, changed, ended }

/// Pen state that accompanies every pen pointer event.
public struct PenState: Equatable, Sendable {
    public var pressure: Double
    public var tiltX: Double
    public var tiltY: Double
    public var eraser: Bool
}

public protocol PointerSink: AnyObject {
    func move(to point: Point, pen: PenState?)
    func button(_ button: MouseButton, down: Bool, at point: Point, clickCount: Int, pen: PenState?)
    func drag(_ button: MouseButton, to point: Point, pen: PenState?)
    /// `dx`/`dy` are how far the content should follow the finger, in points.
    func scroll(dx: Double, dy: Double, phase: ScrollPhase?, momentum: MomentumPhase)
    func penProximity(entering: Bool, eraser: Bool)
}

public struct GestureSettings: Sendable {
    /// Movement (points) before a touch stops being a tap.
    public var tapSlop: Double = 12
    public var longPressDelay: Double = 0.6
    /// A second finger arriving within this time turns a touch into a two-finger gesture.
    public var secondFingerWindow: Double = 0.3
    public var twoFingerTapMaxDuration: Double = 0.35
    public var doubleClickInterval: Double = 0.5
    public var doubleClickDistance: Double = 24
    public var longPressRightClick = true
    public var twoFingerTapRightClick = true
    public var momentumScrolling = true
    public init() {}
}

/// Tracks consecutive clicks so quick repeated taps become double/triple clicks.
struct ClickCounter {
    private var lastTime = -Double.infinity
    private var lastPoint = Point(x: .nan, y: .nan)
    private var count = 0

    mutating func register(at point: Point, now: Double, settings: GestureSettings) -> Int {
        if now - lastTime <= settings.doubleClickInterval, point.distance(to: lastPoint) <= settings.doubleClickDistance {
            count += 1
        } else {
            count = 1
        }
        lastTime = now
        lastPoint = point
        return count
    }
}

public final class TouchGestureEngine {
    private enum State {
        case idle
        /// One finger down, not yet decided between tap, drag and long press.
        case pending(id: Int, start: Point, startTime: Double)
        case dragging(id: Int, last: Point)
        /// Long press fired; ignore everything until all fingers lift.
        case waitForLift
        case scrolling(start: Point, startTime: Double, last: Point, lastTime: Double, moved: Bool, velocity: Point)
        case momentum(velocity: Point, lastTime: Double)
    }

    public var settings: GestureSettings
    private weak var sink: PointerSink?
    private var state = State.idle
    private var clicks = ClickCounter()

    public init(sink: PointerSink, settings: GestureSettings = GestureSettings()) {
        self.sink = sink
        self.settings = settings
    }

    /// True while time-based behaviour (long press, momentum) needs `tick` calls.
    public var needsTick: Bool {
        switch state {
        case .pending, .momentum: return true
        default: return false
        }
    }

    /// Feed a complete frame of contacts, already mapped to screen points.
    public func process(_ contacts: [(id: Int, point: Point)], now: Double) {
        let active = contacts.sorted { $0.id < $1.id }

        if case .momentum = state {
            if active.isEmpty { return }
            sink?.scroll(dx: 0, dy: 0, phase: nil, momentum: .ended)
            state = .idle
        }

        switch state {
        case .idle:
            if active.count >= 2 {
                startScroll(active, now: now)
            } else if let c = active.first {
                sink?.move(to: c.point, pen: nil)
                state = .pending(id: c.id, start: c.point, startTime: now)
            }

        case let .pending(id, start, startTime):
            if active.count >= 2 && now - startTime <= settings.secondFingerWindow {
                startScroll(active, now: now)
            } else if let c = active.first(where: { $0.id == id }) {
                if c.point.distance(to: start) > settings.tapSlop {
                    sink?.button(.left, down: true, at: start, clickCount: 1, pen: nil)
                    sink?.drag(.left, to: c.point, pen: nil)
                    state = .dragging(id: id, last: c.point)
                }
            } else {
                // Finger lifted before moving or long pressing: a tap.
                let count = clicks.register(at: start, now: now, settings: settings)
                sink?.button(.left, down: true, at: start, clickCount: count, pen: nil)
                sink?.button(.left, down: false, at: start, clickCount: count, pen: nil)
                state = active.isEmpty ? .idle : .waitForLift
            }

        case let .dragging(id, last):
            if let c = active.first(where: { $0.id == id }) {
                if c.point != last { sink?.drag(.left, to: c.point, pen: nil) }
                state = .dragging(id: id, last: c.point)
            } else {
                sink?.button(.left, down: false, at: last, clickCount: 1, pen: nil)
                state = active.isEmpty ? .idle : .waitForLift
            }

        case .waitForLift:
            if active.isEmpty { state = .idle }

        case let .scrolling(start, startTime, last, lastTime, moved, velocity):
            if active.count >= 2 {
                let centroid = Self.centroid(active)
                let delta = Point(x: centroid.x - last.x, y: centroid.y - last.y)
                var nowMoved = moved
                if !moved && centroid.distance(to: start) > settings.tapSlop {
                    nowMoved = true
                    sink?.scroll(dx: centroid.x - start.x, dy: centroid.y - start.y, phase: .began, momentum: .none)
                } else if moved && (delta.x != 0 || delta.y != 0) {
                    sink?.scroll(dx: delta.x, dy: delta.y, phase: .changed, momentum: .none)
                }
                let dt = max(now - lastTime, 1.0 / 240)
                let instant = Point(x: delta.x / dt, y: delta.y / dt)
                let smoothed = Point(x: velocity.x * 0.6 + instant.x * 0.4, y: velocity.y * 0.6 + instant.y * 0.4)
                state = .scrolling(start: start, startTime: startTime, last: centroid, lastTime: now,
                                   moved: nowMoved, velocity: smoothed)
            } else {
                if moved {
                    sink?.scroll(dx: 0, dy: 0, phase: .ended, momentum: .none)
                    let speed = (velocity.x * velocity.x + velocity.y * velocity.y).squareRoot()
                    if active.isEmpty && settings.momentumScrolling && speed > 150 && now - lastTime < 0.1 {
                        sink?.scroll(dx: 0, dy: 0, phase: nil, momentum: .began)
                        state = .momentum(velocity: velocity, lastTime: now)
                        return
                    }
                } else if settings.twoFingerTapRightClick && now - startTime <= settings.twoFingerTapMaxDuration {
                    sink?.button(.right, down: true, at: start, clickCount: 1, pen: nil)
                    sink?.button(.right, down: false, at: start, clickCount: 1, pen: nil)
                }
                state = active.isEmpty ? .idle : .waitForLift
            }

        case .momentum:
            break
        }
    }

    public func tick(now: Double) {
        switch state {
        case let .pending(_, start, startTime):
            guard settings.longPressRightClick, now - startTime >= settings.longPressDelay else { return }
            sink?.button(.right, down: true, at: start, clickCount: 1, pen: nil)
            sink?.button(.right, down: false, at: start, clickCount: 1, pen: nil)
            state = .waitForLift

        case let .momentum(velocity, lastTime):
            let dt = now - lastTime
            guard dt > 0 else { return }
            // Exponential decay with a ~0.33 s time constant, similar to trackpad momentum.
            let decay = exp(-dt * 3)
            let v = Point(x: velocity.x * decay, y: velocity.y * decay)
            if (v.x * v.x + v.y * v.y).squareRoot() < 20 {
                sink?.scroll(dx: 0, dy: 0, phase: nil, momentum: .ended)
                state = .idle
            } else {
                sink?.scroll(dx: v.x * dt, dy: v.y * dt, phase: nil, momentum: .changed)
                state = .momentum(velocity: v, lastTime: now)
            }

        default:
            break
        }
    }

    /// Releases any pressed button, e.g. when the device disappears or the pen takes over.
    public func cancel() {
        switch state {
        case let .dragging(_, last):
            sink?.button(.left, down: false, at: last, clickCount: 1, pen: nil)
        case let .scrolling(_, _, _, _, moved, _) where moved:
            sink?.scroll(dx: 0, dy: 0, phase: .ended, momentum: .none)
        case .momentum:
            sink?.scroll(dx: 0, dy: 0, phase: nil, momentum: .ended)
        default:
            break
        }
        state = .idle
    }

    private func startScroll(_ active: [(id: Int, point: Point)], now: Double) {
        let c = Self.centroid(active)
        // Scroll events go to the view under the cursor, so put it between the fingers.
        sink?.move(to: c, pen: nil)
        state = .scrolling(start: c, startTime: now, last: c, lastTime: now, moved: false, velocity: Point(x: 0, y: 0))
    }

    private static func centroid(_ contacts: [(id: Int, point: Point)]) -> Point {
        let two = contacts.prefix(2)
        return Point(x: two.map(\.point.x).reduce(0, +) / Double(two.count),
                     y: two.map(\.point.y).reduce(0, +) / Double(two.count))
    }
}

public final class PenTracker {
    public var settings: GestureSettings
    private weak var sink: PointerSink?
    private var inProximity = false
    private var eraser = false
    private var pressed: MouseButton?
    private var clicks = ClickCounter()
    private var clickCount = 1
    private var lastPoint = Point(x: 0, y: 0)

    public init(sink: PointerSink, settings: GestureSettings = GestureSettings()) {
        self.sink = sink
        self.settings = settings
    }

    public var isActive: Bool { inProximity }

    public func process(_ sample: PenSample, at point: Point, now: Double) {
        let pen = PenState(pressure: sample.pressure, tiltX: sample.tiltX ?? 0, tiltY: sample.tiltY ?? 0,
                           eraser: sample.eraser)
        lastPoint = point

        if sample.inRange && !inProximity {
            inProximity = true
            eraser = sample.eraser
            sink?.penProximity(entering: true, eraser: eraser)
        }

        if sample.tip && pressed == nil {
            // Holding the barrel button while touching down gives a right click.
            let button: MouseButton = sample.barrel ? .right : .left
            clickCount = button == .left ? clicks.register(at: point, now: now, settings: settings) : 1
            pressed = button
            sink?.button(button, down: true, at: point, clickCount: clickCount, pen: pen)
        } else if !sample.tip, let button = pressed {
            sink?.button(button, down: false, at: point, clickCount: clickCount, pen: pen)
            pressed = nil
        } else if let button = pressed {
            sink?.drag(button, to: point, pen: pen)
        } else if sample.inRange {
            sink?.move(to: point, pen: pen)
        }

        if !sample.inRange && inProximity {
            leaveProximity()
        }
    }

    public func cancel() {
        if let button = pressed {
            sink?.button(button, down: false, at: lastPoint, clickCount: clickCount, pen: nil)
            pressed = nil
        }
        if inProximity { leaveProximity() }
    }

    private func leaveProximity() {
        inProximity = false
        sink?.penProximity(entering: false, eraser: eraser)
    }
}
