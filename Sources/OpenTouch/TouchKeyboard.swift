import AppKit
import ApplicationServices
import OpenTouchCore

// An on-screen keyboard that pops up on the touch display when a text field is tapped.
//
// It never becomes key or active, so the app being typed into keeps focus. Keys
// are typed by posting keyboard events with the character attached, which works
// regardless of the active keyboard layout.

private enum KeyAction: Equatable {
    case text(String)
    case backspace, enter, tab, space, left, right, shift, hide
    case layer(KeyboardLayer)
}

private enum KeyboardLayer: Equatable {
    case letters, numbers, symbols
}

private struct Key {
    let label: String
    let action: KeyAction
    /// Relative width; a letter key is 1.
    let width: CGFloat
    var isFunction: Bool {
        if case .text = action { return false }
        return action != .space
    }

    init(_ label: String, _ action: KeyAction, width: CGFloat = 1) {
        self.label = label
        self.action = action
        self.width = width
    }

    static func chars(_ s: String) -> [Key] { s.map { Key(String($0), .text(String($0))) } }
}

private enum ShiftState { case off, once, locked }

/// Posts typed text and editing keys to whatever app has keyboard focus.
private enum KeyTyper {
    private static let source = CGEventSource(stateID: .hidSystemState)

    static func type(_ text: String) {
        let utf16 = Array(text.utf16)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
            event.flags = []
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            event.post(tap: .cghidEventTap)
        }
    }

    static func press(keyCode: CGKeyCode) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            event.flags = []
            event.post(tap: .cghidEventTap)
        }
    }
}

final class KeyboardView: NSView {
    fileprivate var onHide: (() -> Void)?

    private var layer_ = KeyboardLayer.letters
    private var shift = ShiftState.once
    private var lastShiftTap = 0.0
    private var keyFrames: [(key: Key, frame: NSRect)] = []
    /// Keys currently held, by touch contact ID (-1 for the mouse).
    private var pressed: [Int: Key] = [:]
    private var repeatTimer: Timer?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var rows: [[Key]] {
        switch layer_ {
        case .letters:
            let upper = shift != .off
            func letters(_ s: String) -> [Key] { Key.chars(upper ? s.uppercased() : s) }
            let shiftLabel = shift == .locked ? "⇪" : "⇧"
            return [
                [Key("⇥", .tab, width: 1.3)] + letters("qwertyuiop") + [Key("⌫", .backspace, width: 1.5)],
                [Key("", .layer(.letters), width: 0.6)] + letters("asdfghjkl") + [Key("return", .enter, width: 2.2)],
                [Key(shiftLabel, .shift, width: 1.6)] + letters("zxcvbnm") + Key.chars(",.")
                    + [Key(shiftLabel, .shift, width: 1.6)],
                bottomRow(layerKey: Key(".?123", .layer(.numbers), width: 1.6)),
            ]
        case .numbers:
            return [
                Key.chars("1234567890") + [Key("⌫", .backspace, width: 1.5)],
                Key.chars("-/:;()€&@\"") + [Key("return", .enter, width: 1.5)],
                [Key("#+=", .layer(.symbols), width: 1.6)] + Key.chars(".,?!'") + [Key("#+=", .layer(.symbols), width: 1.6)],
                bottomRow(layerKey: Key("ABC", .layer(.letters), width: 1.6)),
            ]
        case .symbols:
            return [
                Key.chars("[]{}#%^*+=") + [Key("⌫", .backspace, width: 1.5)],
                Key.chars("_\\|~<>$£¥•") + [Key("return", .enter, width: 1.5)],
                [Key("123", .layer(.numbers), width: 1.6)] + Key.chars(".,?!'`") + [Key("123", .layer(.numbers), width: 1.6)],
                bottomRow(layerKey: Key("ABC", .layer(.letters), width: 1.6)),
            ]
        }
    }

    private func bottomRow(layerKey: Key) -> [Key] {
        [layerKey, Key(" ", .space, width: 6), Key("←", .left), Key("→", .right),
         Key("⌨︎↓", .hide, width: 1.4)]
    }

    func reset() {
        layer_ = .letters
        shift = .once
        pressed = [:]
        stopRepeat()
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let padding: CGFloat = 8
        let gap: CGFloat = 7
        let rows = rows
        let rowHeight = (bounds.height - padding * 2 - gap * CGFloat(rows.count - 1)) / CGFloat(rows.count)
        // Every row spans the full width, so all rows share the widest row's unit size.
        let unit = rows.map { (row: [Key]) -> CGFloat in
            let available: CGFloat = bounds.width - padding * 2 - gap * CGFloat(row.count - 1)
            let units: CGFloat = row.reduce(0) { $0 + $1.width }
            return available / units
        }.min() ?? 0

        keyFrames = []
        for (r, row) in rows.enumerated() {
            let keysWidth: CGFloat = row.reduce(0) { $0 + $1.width * unit }
            let total = keysWidth + gap * CGFloat(row.count - 1)
            var x = (bounds.width - total) / 2
            let y = padding + CGFloat(r) * (rowHeight + gap)
            for key in row {
                let w = key.width * unit
                // The blank spacer before "a" only offsets the row, it is not a key.
                if !(key.label.isEmpty && key.action == .layer(.letters)) {
                    keyFrames.append((key, NSRect(x: x, y: y, width: w, height: rowHeight)))
                }
                x += w + gap
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let fontSize = (keyFrames.first?.frame.height ?? 40) * 0.38
        for (key, frame) in keyFrames {
            let isPressed = pressed.values.contains { $0.label == key.label && $0.action == key.action }
            let active = key.action == .shift && shift != .off
            let color: NSColor = isPressed ? .selectedContentBackgroundColor
                : (key.isFunction ? (active ? .controlAccentColor.withAlphaComponent(0.6) : .tertiaryLabelColor)
                   : .controlBackgroundColor)
            color.setFill()
            NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8).fill()

            let size = key.label.count > 2 ? fontSize * 0.6 : fontSize
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: .regular),
                .foregroundColor: isPressed ? NSColor.white : NSColor.labelColor,
            ]
            let text = NSAttributedString(string: key.label, attributes: attributes)
            let textSize = text.size()
            text.draw(at: NSPoint(x: frame.midX - textSize.width / 2, y: frame.midY - textSize.height / 2))
        }
    }

    // MARK: Input

    /// `point` is in this view's coordinates.
    func press(contact: Int, at point: NSPoint) {
        guard let key = keyFrames.first(where: { $0.frame.contains(point) })?.key else { return }
        pressed[contact] = key
        if key.action == .backspace {
            // Delete right away and keep deleting while held, like a hardware key.
            KeyTyper.press(keyCode: 51)
            repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
                self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { _ in
                    KeyTyper.press(keyCode: 51)
                }
            }
        }
        needsDisplay = true
    }

    func release(contact: Int) {
        guard let key = pressed.removeValue(forKey: contact) else { return }
        if key.action == .backspace { stopRepeat() }
        perform(key.action)
        needsDisplay = true
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    private func perform(_ action: KeyAction) {
        switch action {
        case let .text(s):
            KeyTyper.type(s)
            if shift == .once {
                shift = .off
                needsLayout = true
            }
        case .space:
            KeyTyper.type(" ")
        case .backspace:
            break // handled on press
        case .enter: KeyTyper.press(keyCode: 36)
        case .tab: KeyTyper.press(keyCode: 48)
        case .left: KeyTyper.press(keyCode: 123)
        case .right: KeyTyper.press(keyCode: 124)
        case .shift:
            let now = ProcessInfo.processInfo.systemUptime
            // Double tap locks caps, like on iOS.
            if shift == .once && now - lastShiftTap < 0.35 {
                shift = .locked
            } else {
                shift = shift == .off ? .once : .off
            }
            lastShiftTap = now
            needsLayout = true
        case let .layer(l):
            layer_ = l
            needsLayout = true
        case .hide:
            onHide?()
        }
    }

    override func mouseDown(with event: NSEvent) {
        press(contact: -1, at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        release(contact: -1)
    }
}

private final class KeyboardPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Decides when the keyboard shows and where.
final class TouchKeyboard {
    var autoShow = true

    private let panel = KeyboardPanel()
    private let keyboard = KeyboardView()
    private let mapper: DisplayMapper
    private var manuallyShown = false
    private var focusPoll: Timer?
    private var accessibilityEnabledPIDs = Set<pid_t>()

    init(mapper: DisplayMapper) {
        self.mapper = mapper
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        keyboard.autoresizingMask = [.width, .height]
        background.addSubview(keyboard)
        panel.contentView = background
        keyboard.onHide = { [weak self] in self?.hide() }
    }

    var isVisible: Bool { panel.isVisible }

    /// True when a global (CGEvent, top-left origin) point is on the keyboard.
    func contains(_ point: Point) -> Bool {
        isVisible && panel.frame.contains(Self.cocoaPoint(point))
    }

    func touchDown(contact: Int, at point: Point) {
        let local = keyboard.convert(panel.convertPoint(fromScreen: Self.cocoaPoint(point)), from: nil)
        keyboard.press(contact: contact, at: local)
    }

    func touchUp(contact: Int) {
        keyboard.release(contact: contact)
    }

    /// Called after every tap outside the keyboard: show or hide depending on what got focus.
    func pointerClicked() {
        guard autoShow else { return }
        // Give the app a moment to move focus to what was tapped.
        for delay in [0.12, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.updateForFocus(fromTap: true) }
        }
    }

    func toggle() {
        if isVisible { hide() } else { show(avoiding: nil, manual: true) }
    }

    func hide() {
        panel.orderOut(nil)
        manuallyShown = false
        focusPoll?.invalidate()
        focusPoll = nil
    }

    private func updateForFocus(fromTap: Bool) {
        if let field = focusedTextField() {
            if !isVisible { show(avoiding: field.frame, manual: false) }
        } else if isVisible && !manuallyShown {
            hide()
        }
    }

    private func show(avoiding fieldFrame: CGRect?, manual: Bool) {
        guard let displayID = mapper.targetDisplay(),
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
              })
        else { return }

        let visible = screen.visibleFrame
        let width = min(visible.width - 16, 1500)
        let height = min(width * 0.3, visible.height * 0.42)
        var frame = NSRect(x: visible.midX - width / 2, y: visible.minY + 8, width: width, height: height)
        // Don't cover the field being typed into: move to the top of the screen instead.
        if let fieldFrame, frame.intersects(Self.cocoaRect(fieldFrame)) {
            frame.origin.y = visible.maxY - height - 8
        }

        keyboard.reset()
        panel.setFrame(frame, display: true)
        keyboard.frame = panel.contentView!.bounds
        panel.orderFrontRegardless()
        manuallyShown = manual

        focusPoll?.invalidate()
        focusPoll = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            guard let self, !manuallyShown else { return }
            // Focus moved away by other means (mouse, keyboard shortcut, app switch).
            if focusedTextField() == nil { hide() }
        }
    }

    // MARK: Accessibility

    private func focusedTextField() -> (element: AXUIElement, frame: CGRect?)? {
        let system = AXUIElementCreateSystemWide()
        enableWebAccessibility(system)
        guard let element: AXUIElement = Self.attribute(system, kAXFocusedUIElementAttribute) else { return nil }

        let role: String = Self.attribute(element, kAXRoleAttribute) ?? ""
        var editable = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)
        if !editable {
            // Web content and custom controls: anything whose text selection can be set is editable.
            var settable: DarwinBoolean = false
            editable = AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success
                && settable.boolValue
        }
        guard editable else { return nil }

        var frame: CGRect?
        if let position: AXValue = Self.attribute(element, kAXPositionAttribute),
           let size: AXValue = Self.attribute(element, kAXSizeAttribute) {
            var p = CGPoint.zero
            var s = CGSize.zero
            AXValueGetValue(position, .cgPoint, &p)
            AXValueGetValue(size, .cgSize, &s)
            frame = CGRect(origin: p, size: s)
        }
        return (element, frame)
    }

    /// Chrome and Electron apps only expose web page text fields once an assistive app asks for it.
    private func enableWebAccessibility(_ system: AXUIElement) {
        guard let app: AXUIElement = Self.attribute(system, kAXFocusedApplicationAttribute) else { return }
        var pid: pid_t = 0
        guard AXUIElementGetPid(app, &pid) == .success, accessibilityEnabledPIDs.insert(pid).inserted else { return }
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    // MARK: Coordinates

    // CGEvent / Accessibility use a top-left origin on the primary display; AppKit uses bottom-left.
    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    private static func cocoaPoint(_ p: Point) -> NSPoint {
        NSPoint(x: p.x, y: primaryHeight - p.y)
    }

    private static func cocoaRect(_ r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}
