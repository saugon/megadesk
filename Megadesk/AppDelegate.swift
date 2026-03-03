import AppKit
import SwiftUI
import Carbon.HIToolbox
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: FloatingWindowController?
    private var statusItem: NSStatusItem?
    private var onboardingController: OnboardingWindowController?
    private var helpController: HelpWindowController?
    private var settingsController: SettingsWindowController?
    private var hotKeyRef: EventHotKeyRef?
    private var sessionHotKeyRefs: [EventHotKeyRef?] = []
    private var updaterController: SPUStandardUpdaterController!

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        if UserDefaults.standard.bool(forKey: "megadesk.onboardingComplete") {
            windowController?.show()
        } else {
            onboardingController = OnboardingWindowController {
                self.onboardingController = nil
                self.windowController?.show()
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
                        delegate.windowController?.toggle()
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
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let helpItem = NSMenuItem(title: "Help", action: #selector(openHelp), keyEquivalent: "")
        helpItem.target = self
        menu.addItem(helpItem)
        menu.addItem(.separator())
        let updateItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(SPUUpdater.checkForUpdates),
            keyEquivalent: ""
        )
        updateItem.target = updaterController.updater
        menu.addItem(updateItem)
        menu.addItem(withTitle: "Quit Megadesk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem?.menu = menu
    }

    @objc private func toggleWidget() {
        windowController?.toggle()
    }

    @objc private func toggleCompact() {
        windowController?.toggleCompact()
    }

    @objc private func togglePRTracking() {
        let key = "megadesk.prTracking"
        let current = UserDefaults.standard.object(forKey: key) as? Bool ?? true
        UserDefaults.standard.set(!current, forKey: key)
    }

    @objc private func openSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController()
        }
        settingsController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openHelp() {
        if helpController == nil {
            helpController = HelpWindowController()
        }
        helpController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - NSMenuDelegate — refresh title before menu appears

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        let isVisible = windowController?.isWidgetVisible ?? false
        menu.item(at: 0)?.title = isVisible ? "Hide Widget" : "Show Widget"
        menu.item(at: 1)?.state = (windowController?.isCompact ?? false) ? .on : .off
        let prEnabled = UserDefaults.standard.object(forKey: "megadesk.prTracking") as? Bool ?? true
        menu.item(withTag: 10)?.state = prEnabled ? .on : .off
    }
}

// MARK: - NSWindowDelegate — close button hides instead of quitting

extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        windowController?.hide()
        return false
    }
}
