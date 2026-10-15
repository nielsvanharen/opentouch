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
    private(set) lazy var keyboard = TouchKeyboard(mapper: mapper)
    /// Contacts that started on the on-screen keyboard; they type instead of driving gestures.
    private var keyboardContacts = Set<Int>()
    private var knownContacts = Set<Int>()

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
        poster.onClick = { [weak self] in self?.keyboard.pointerClicked() }
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
            touch.process(routeKeyboardContacts(mapped), now: now)
            updateTickTimer()
        }
    }

    /// Sends new contacts that land on the keyboard to it and returns the rest.
    private func routeKeyboardContacts(_ contacts: [(id: Int, point: Point)]) -> [(id: Int, point: Point)] {
        let ids = Set(contacts.map(\.id))
        for id in keyboardContacts.subtracting(ids) { keyboard.touchUp(contact: id) }
        keyboardContacts.formIntersection(ids)

        for c in contacts where !knownContacts.contains(c.id) && keyboard.contains(c.point) {
            keyboardContacts.insert(c.id)
            keyboard.touchDown(contact: c.id, at: c.point)
        }
        knownContacts = ids
        return contacts.filter { !keyboardContacts.contains($0.id) }
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
