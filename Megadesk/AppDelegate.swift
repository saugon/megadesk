import AppKit
import SwiftUI
import Carbon.HIToolbox
import Sparkle
import ObjectiveC

// Swizzle NSMenuItem.image to suppress macOS auto-injected icons (gear on Settings, etc.)
extension NSMenuItem {
    static func disableAutoIcons() {
        guard let original = class_getInstanceMethod(NSMenuItem.self, #selector(getter: image)),
              let replacement = class_getInstanceMethod(NSMenuItem.self, #selector(_nilImage)) else { return }
        method_exchangeImplementations(original, replacement)
    }
    @objc private func _nilImage() -> NSImage? { nil }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: FloatingWindowController?
    private var statusItem: NSStatusItem?
    private var onboardingController: OnboardingWindowController?
    private var mainController: MainWindowController?
    private var hotKeyRef: EventHotKeyRef?
    private var sessionHotKeyRefs: [EventHotKeyRef?] = []
    private var updaterController: SPUStandardUpdaterController!
    private var contextSaveController: ContextSaveWindowController?
    private var companionController: CompanionWindowController?
    private var alertBadgeObserver: Any?
    private var originalMenuBarIcon: NSImage?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSMenuItem.disableAutoIcons()

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        // Terminate any previously running instance before setting up.
        if let bundleID = Bundle.main.bundleIdentifier {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0 != NSRunningApplication.current }
                .forEach { $0.terminate() }
        }

        // Always update the hook script from the bundle so it stays in sync with the app.
        try? HookInstaller.install()

        let contentView = ContentView()
        windowController = FloatingWindowController(contentView: contentView, footerView: contentView.footerView)
        windowController?.window?.delegate = self
        setupMenuBar()
        registerGlobalHotKey()

        // Silently update hook scripts on every launch (copies latest bundled scripts,
        // patches config files only if not yet registered).
        for provider in Provider.allCases {
            try? HookInstaller.install(provider: provider)
        }

        AlertNotificationService.shared.setup()
        setupAlertBadge()

        // Companion ghost
        _ = CompanionEngine.shared  // bootstrap observation
        companionController = CompanionWindowController(mainWidgetWindow: windowController?.window)
        observeCompanionMode()

        NotificationCenter.default.addObserver(forName: .megadeskOpenContextSave, object: nil, queue: .main) { [weak self] _ in
            self?.openContextSave()
        }
        let storedVersion = UserDefaults.standard.integer(forKey: "megadesk.onboardingVersion")
        if storedVersion >= OnboardingView.currentOnboardingVersion {
            windowController?.show()
            showCompanionIfFloating()
        } else {
            let isReturningUser = UserDefaults.standard.bool(forKey: "megadesk.onboardingComplete")
            onboardingController = OnboardingWindowController(isReturningUser: isReturningUser, previousVersion: storedVersion) {
                self.onboardingController = nil
                self.windowController?.show()
                self.showCompanionIfFloating()
            }
            onboardingController?.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Global hotkey (⌘⇧M)

    private func registerGlobalHotKey() {
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = 0x4d47444b  // 'MGDK'
        hotKeyID.id = 1

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            // Parameters: (EventHandlerCallRef, EventRef, userData) — callRef is first, event is second.
            { _, inEvent, userData -> OSStatus in
                guard let ptr = userData, let event = inEvent else { return noErr }
                var hkID = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hkID)
                let capturedID = hkID.id
                DispatchQueue.main.async {
                    let delegate = Unmanaged<AppDelegate>.fromOpaque(ptr).takeUnretainedValue()
                    if capturedID == 1 {
                        delegate.toggleWidget()
                    } else if capturedID >= 2 && capturedID <= 10 {
                        NotificationCenter.default.post(
                            name: .megadeskFocusSession,
                            object: nil,
                            userInfo: ["index": Int(capturedID) - 2]
                        )
                    } else if capturedID == 11 || capturedID == 12 {
                        delegate.windowController?.show()
                        NotificationCenter.default.post(name: .megadeskCycleSession, object: nil,
                                                        userInfo: ["forward": capturedID == 12])
                    } else if capturedID == 13 {
                        delegate.windowController?.show()
                        delegate.windowController?.showQuickAlert()
                    } else if capturedID == 14 {
                        delegate.openContextSave()
                    } else if capturedID == 15 {
                        CompanionEngine.shared.emitTestMessage()
                    } else if capturedID == 16 {
                        delegate.togglePet()
                    }
                }
                return noErr
            },
            1,
            &eventSpec,
            selfPtr,
            nil
        )

        RegisterEventHotKey(
            UInt32(kVK_ANSI_M),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(0),
            &hotKeyRef
        )

        // ⌥⌘1 through ⌥⌘9 — focus session by order (hotkey IDs 2–10)
        let keyCodes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (i, keyCode) in keyCodes.enumerated() {
            var hkID = EventHotKeyID()
            hkID.signature = 0x4d47444b
            hkID.id = UInt32(i + 2)
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(keyCode), UInt32(cmdKey | optionKey),
                                hkID, GetApplicationEventTarget(), OptionBits(0), &ref)
            sessionHotKeyRefs.append(ref)
        }

        // ⇧⌥↑ / ⇧⌥↓ — cycle through sessions (hotkey IDs 11/12)
        for (id, keyCode) in [(11, kVK_UpArrow), (12, kVK_DownArrow)] {
            var hkID = EventHotKeyID()
            hkID.signature = 0x4d47444b
            hkID.id = UInt32(id)
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(keyCode), UInt32(shiftKey | optionKey),
                                hkID, GetApplicationEventTarget(), OptionBits(0), &ref)
            sessionHotKeyRefs.append(ref)
        }

        // ⌘⇧A — quick alert popover (hotkey ID 13)
        var quickAlertHkID = EventHotKeyID()
        quickAlertHkID.signature = 0x4d47444b
        quickAlertHkID.id = 13
        var qaRef: EventHotKeyRef?
        RegisterEventHotKey(UInt32(kVK_ANSI_A), UInt32(cmdKey | shiftKey),
                            quickAlertHkID, GetApplicationEventTarget(), OptionBits(0), &qaRef)
        sessionHotKeyRefs.append(qaRef)

        // ⌘⇧C — context save (hotkey ID 14)
        var contextHkID = EventHotKeyID()
        contextHkID.signature = 0x4d47444b
        contextHkID.id = 14
        var csRef: EventHotKeyRef?
        RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(cmdKey | shiftKey),
                            contextHkID, GetApplicationEventTarget(), OptionBits(0), &csRef)
        sessionHotKeyRefs.append(csRef)

        // ⌘⇧L — companion test message (hotkey ID 15)
        var companionHkID = EventHotKeyID()
        companionHkID.signature = 0x4d47444b
        companionHkID.id = 15
        var compRef: EventHotKeyRef?
        RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(cmdKey | shiftKey),
                            companionHkID, GetApplicationEventTarget(), OptionBits(0), &compRef)
        sessionHotKeyRefs.append(compRef)

        // ⌘⇧. — toggle pet visibility (hotkey ID 16)
        var petHkID = EventHotKeyID()
        petHkID.signature = 0x4d47444b
        petHkID.id = 16
        var petRef: EventHotKeyRef?
        RegisterEventHotKey(UInt32(kVK_ANSI_Period), UInt32(cmdKey | shiftKey),
                            petHkID, GetApplicationEventTarget(), OptionBits(0), &petRef)
        sessionHotKeyRefs.append(petRef)
    }

    // MARK: - Menu bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            let icon = NSImage(named: "MenuBarIcon")
            icon?.size = NSSize(width: 18, height: 18)
            icon?.isTemplate = true
            button.image = icon
        }
        let menu = NSMenu()
        menu.delegate = self
        let toggleItem = menu.addItem(withTitle: "Hide Widget", action: #selector(toggleWidget), keyEquivalent: "M")
        toggleItem.target = self
        let compactItem = NSMenuItem(title: "Compact Mode", action: #selector(toggleCompact), keyEquivalent: "")
        compactItem.target = self
        menu.addItem(compactItem)
        let prItem = NSMenuItem(title: "Show PR Tracking", action: #selector(togglePRTracking), keyEquivalent: "")
        prItem.target = self
        prItem.tag = 10
        menu.addItem(prItem)
        menu.addItem(.separator())
        let alertsItem = NSMenuItem(title: "Alerts...", action: #selector(openAlerts), keyEquivalent: "")
        alertsItem.target = self
        menu.addItem(alertsItem)
        let contextItem = NSMenuItem(title: "Context Note...", action: #selector(openContextSave), keyEquivalent: "")
        contextItem.target = self
        menu.addItem(contextItem)
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let helpItem = NSMenuItem(title: "Help", action: #selector(openHelp), keyEquivalent: "")
        helpItem.target = self
        menu.addItem(helpItem)
        menu.addItem(.separator())
        let updateItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        updateItem.target = self
        menu.addItem(updateItem)
        menu.addItem(withTitle: "Quit Megadesk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem?.menu = menu
        windowController?.setMenu(menu)
    }

    @objc private func toggleWidget() {
        windowController?.toggle()
        if windowController?.isWidgetVisible == true {
            showCompanionIfFloating()
        } else {
            companionController?.hide()
        }
    }

    private func showCompanionIfFloating() {
        guard AppSettings.shared.companionMode == .floating else { return }
        companionController?.show()
    }

    /// Observe changes to the companion mode so we hide the floating window
    /// when the user switches to docked (and show it again when switching back).
    private func observeCompanionMode() {
        withObservationTracking {
            _ = AppSettings.shared.companionMode
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if AppSettings.shared.companionMode == .floating,
                   self.windowController?.isWidgetVisible == true,
                   AppSettings.shared.companionEnabled {
                    self.companionController?.show()
                } else {
                    self.companionController?.hide()
                }
                self.observeCompanionMode()
            }
        }
    }

    @objc func togglePet() {
        let settings = AppSettings.shared
        settings.companionEnabled.toggle()
        settings.save()

        if settings.companionEnabled {
            showCompanionIfFloating()
        } else {
            companionController?.hide()
        }
    }

    @objc private func toggleCompact() {
        windowController?.toggleCompact()
    }

    @objc private func togglePRTracking() {
        let key = "megadesk.prTracking"
        let current = UserDefaults.standard.object(forKey: key) as? Bool ?? true
        UserDefaults.standard.set(!current, forKey: key)
    }

    private func showMain(section: MainSection) {
        if mainController == nil {
            mainController = MainWindowController()
        }
        mainController?.show(section: section)
    }

    @objc private func openSettings() {
        showMain(section: .settings)
    }

    @objc private func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(self)
    }

    @objc private func openHelp() {
        showMain(section: .help)
    }

    @objc private func openContextSave() {
        if contextSaveController == nil {
            contextSaveController = ContextSaveWindowController()
        }
        contextSaveController?.showForInput()
    }

    @objc private func openAlerts() {
        showMain(section: .alerts)
    }

    // MARK: - Alert badge

    private func setupAlertBadge() {
        originalMenuBarIcon = statusItem?.button?.image

        alertBadgeObserver = NotificationCenter.default.addObserver(
            forName: .megadeskAlertFired, object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateMenuBarBadge()
        }

        // Also refresh whenever the underlying alerts state changes — covers
        // dismiss, delete, snooze, and any other path that doesn't fire the
        // notification above. Without this the badge would persist after
        // every non-fire mutation.
        observePendingAlerts()
    }

    private func observePendingAlerts() {
        withObservationTracking {
            _ = StatusStore.shared.pendingAlertCount
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.updateMenuBarBadge()
                self?.observePendingAlerts()
            }
        }
    }

    private func updateMenuBarBadge() {
        guard let button = statusItem?.button else { return }
        let store = StatusStore.shared
        if store.pendingAlertCount > 0 {
            // Composite a small orange dot onto the menu bar icon
            guard let baseIcon = originalMenuBarIcon else { return }
            let size = baseIcon.size
            let badged = NSImage(size: size, flipped: false) { rect in
                baseIcon.draw(in: rect)
                let dotSize: CGFloat = 6
                let dotRect = NSRect(x: size.width - dotSize - 1, y: size.height - dotSize - 1,
                                     width: dotSize, height: dotSize)
                NSColor(AppSettings.shared.colorAlert).setFill()
                NSBezierPath(ovalIn: dotRect).fill()
                return true
            }
            badged.isTemplate = false
            button.image = badged
        } else {
            let icon = originalMenuBarIcon ?? NSImage(named: "MenuBarIcon")
            icon?.isTemplate = true
            button.image = icon
        }
    }
}

// MARK: - NSMenuDelegate — refresh title before menu appears

extension AppDelegate: NSMenuDelegate {
    private static let alertMenuItemTag = 900

    func menuWillOpen(_ menu: NSMenu) {
        // Remove dynamic alert items first so fixed indices are correct
        while let old = menu.item(withTag: Self.alertMenuItemTag) {
            menu.removeItem(old)
        }

        let isVisible = windowController?.isWidgetVisible ?? false
        menu.item(at: 0)?.title = isVisible ? "Hide Widget" : "Show Widget"
        menu.item(at: 1)?.state = (windowController?.isCompact ?? false) ? .on : .off
        let prEnabled = UserDefaults.standard.object(forKey: "megadesk.prTracking") as? Bool ?? true
        menu.item(withTag: 10)?.state = prEnabled ? .on : .off

        // Add fired-alert items at the very top
        let store = StatusStore.shared
        let pending = store.alerts.filter {
            store.firedAlertIds.contains($0.id) && !store.dismissedFiredAlertIds.contains($0.id)
        }
        guard !pending.isEmpty else { return }

        for (i, alert) in pending.reversed().enumerated() {
            let item = NSMenuItem(title: "🔔 \(alert.title)", action: #selector(dismissFiredAlert(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Self.alertMenuItemTag
            item.representedObject = alert.id
            item.toolTip = "Click to dismiss"
            menu.insertItem(item, at: i)
        }
        let sep = NSMenuItem.separator()
        sep.tag = Self.alertMenuItemTag
        menu.insertItem(sep, at: pending.count)
    }
}

extension AppDelegate {
    @objc private func dismissFiredAlert(_ sender: NSMenuItem) {
        guard let alertId = sender.representedObject as? UUID else { return }
        StatusStore.shared.dismissFiredAlert(id: alertId)
        updateMenuBarBadge()
    }
}

// MARK: - NSWindowDelegate — close button hides instead of quitting

extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        windowController?.hide()
        companionController?.hide()
        return false
    }
}
