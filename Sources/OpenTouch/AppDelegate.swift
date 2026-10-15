import AppKit
import ApplicationServices
import IOKit.hid
import OpenTouchCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = TouchController()
    private var statusItem: NSStatusItem!
    private let defaults = UserDefaults.standard

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: [
            "enabled": true, "palmRejection": true, "longPressRightClick": true,
            "twoFingerTapRightClick": true, "momentumScrolling": true, "popupKeyboard": true,
        ])
        applyDefaults()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "hand.point.up.left", accessibilityDescription: "OpenTouch")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        controller.hid.onPermissionDenied = {
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        controller.hid.onDevicesChanged = { [weak self] in self?.updateIcon() }
        controller.start()

        if !AXIsProcessTrusted() { promptForAccessibility() }
        updateIcon()
    }

    private func applyDefaults() {
        controller.enabled = defaults.bool(forKey: "enabled")
        controller.palmRejection = defaults.bool(forKey: "palmRejection")
        controller.keyboard.autoShow = defaults.bool(forKey: "popupKeyboard")
        if !controller.keyboard.autoShow && controller.keyboard.isVisible { controller.keyboard.hide() }
        var s = controller.settings
        s.longPressRightClick = defaults.bool(forKey: "longPressRightClick")
        s.twoFingerTapRightClick = defaults.bool(forKey: "twoFingerTapRightClick")
        s.momentumScrolling = defaults.bool(forKey: "momentumScrolling")
        controller.settings = s
    }

    private func updateIcon() {
        let ok = controller.enabled && !controller.hid.devices.isEmpty && AXIsProcessTrusted()
        statusItem.button?.appearsDisabled = !ok
    }

    private func promptForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        updateIcon()

        let devices = controller.hid.devices
        if devices.isEmpty {
            menu.addItem(disabled: "No touch screen or pen found")
        } else {
            for d in devices {
                let kinds = [d.decoder.hasTouch ? "touch" : nil, d.decoder.hasPen ? "pen" : nil].compactMap { $0 }
                menu.addItem(disabled: "\(d.name) (\(kinds.joined(separator: " + ")))")
            }
        }
        if !AXIsProcessTrusted() {
            menu.addItem(.separator())
            menu.addItem(action: "Grant Accessibility Permission…", #selector(openAccessibility), target: self)
        }

        menu.addItem(.separator())
        menu.addItem(toggle: "Enabled", key: "enabled", target: self)

        let displayItem = NSMenuItem(title: "Touch Screen Display", action: nil, keyEquivalent: "")
        let displays = NSMenu()
        let auto = displays.addItem(action: "Automatic", #selector(chooseDisplay(_:)), target: self)
        auto.state = controller.mapper.chosen == nil ? .on : .off
        let target = controller.mapper.targetDisplay()
        displays.addItem(.separator())
        for screen in DisplayMapper.screens() {
            let item = displays.addItem(action: screen.name, #selector(chooseDisplay(_:)), target: self)
            item.representedObject = NSNumber(value: screen.id)
            item.state = controller.mapper.chosen == DisplayIdentity(screen.id) ? .on
                : (controller.mapper.chosen == nil && screen.id == target ? .mixed : .off)
        }
        displayItem.submenu = displays
        menu.addItem(displayItem)

        let gestureItem = NSMenuItem(title: "Gestures", action: nil, keyEquivalent: "")
        let gestures = NSMenu()
        gestures.addItem(toggle: "Long Press for Right Click", key: "longPressRightClick", target: self)
        gestures.addItem(toggle: "Two-Finger Tap for Right Click", key: "twoFingerTapRightClick", target: self)
        gestures.addItem(toggle: "Momentum Scrolling", key: "momentumScrolling", target: self)
        gestures.addItem(toggle: "Ignore Touch While Pen Is Near", key: "palmRejection", target: self)
        gestureItem.submenu = gestures
        menu.addItem(gestureItem)

        menu.addItem(toggle: "Pop-up Keyboard for Text Fields", key: "popupKeyboard", target: self)
        menu.addItem(action: controller.keyboard.isVisible ? "Hide Keyboard" : "Show Keyboard",
                     #selector(toggleKeyboard), target: self)

        menu.addItem(.separator())
        let login = menu.addItem(action: "Open at Login", #selector(toggleLogin(_:)), target: self)
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(action: "OpenTouch on GitHub", #selector(openGitHub), target: self)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit OpenTouch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func toggleDefault(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        defaults.set(!defaults.bool(forKey: key), forKey: key)
        applyDefaults()
        updateIcon()
    }

    @objc func toggleKeyboard() {
        controller.keyboard.toggle()
    }

    @objc func chooseDisplay(_ sender: NSMenuItem) {
        controller.mapper.chosen = (sender.representedObject as? NSNumber).map { DisplayIdentity($0.uint32Value) }
    }

    @objc func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.info("Open at Login failed: \(error.localizedDescription)")
        }
    }

    @objc func openAccessibility() {
        promptForAccessibility()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func openGitHub() {
        NSWorkspace.shared.open(URL(string: "https://github.com/nielsvanharen/opentouch")!)
    }
}

private extension NSMenu {
    @discardableResult
    func addItem(action title: String, _ selector: Selector, target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = target
        addItem(item)
        return item
    }

    func addItem(disabled title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
    }

    func addItem(toggle title: String, key: String, target: AppDelegate) {
        let item = addItem(action: title, #selector(AppDelegate.toggleDefault(_:)), target: target)
        item.representedObject = key
        item.state = UserDefaults.standard.bool(forKey: key) ? .on : .off
    }
}
