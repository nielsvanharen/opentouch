import Foundation
import OpenTouchCore

/// Routes decoded digitizer events through display mapping and gesture recognition.
final class TouchController {
    let mapper = DisplayMapper()
    let hid: HIDService
    private let poster = EventPoster()
    private lazy var touch = TouchGestureEngine(sink: poster)
    private lazy var pen = PenTracker(sink: poster)
    private var tickTimer: Timer?
    private var lastPenActivity = -Double.infinity

    var enabled = true {
        didSet { if !enabled { touch.cancel(); pen.cancel() } }
    }
    /// Ignore fingers (palms) while the pen is near the screen.
    var palmRejection = true

    var settings: GestureSettings {
        get { touch.settings }
        set { touch.settings = newValue; pen.settings = newValue }
    }

    init(seize: Bool = true) {
        hid = HIDService(seize: seize)
        hid.onEvent = { [weak self] event, _ in self?.handle(event) }
    }

    func start() { hid.start() }

    private func handle(_ event: DigitizerEvent) {
        guard enabled else { return }
        let now = ProcessInfo.processInfo.systemUptime

        switch event {
        case let .pen(sample):
            guard let point = mapper.map(x: sample.x, y: sample.y) else { return }
            if sample.inRange && !pen.isActive { touch.cancel() }
            pen.process(sample, at: point, now: now)
            lastPenActivity = now

        case let .touchFrame(contacts):
            if palmRejection && (pen.isActive || now - lastPenActivity < 0.5) { return }
            let mapped = contacts.filter(\.touching).compactMap { c in
                mapper.map(x: c.x, y: c.y).map { (id: c.id, point: $0) }
            }
            touch.process(mapped, now: now)
            updateTickTimer()
        }
    }

    private func updateTickTimer() {
        if touch.needsTick, tickTimer == nil {
            tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
                guard let self else { return }
                touch.tick(now: ProcessInfo.processInfo.systemUptime)
                if !touch.needsTick { tickTimer?.invalidate(); tickTimer = nil }
            }
        } else if !touch.needsTick {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }
}
