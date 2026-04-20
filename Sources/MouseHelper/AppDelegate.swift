import Cocoa
import ApplicationServices

class AppDelegate: NSObject, NSApplicationDelegate {

    // The status bar item (the icon in the menu bar).
    // We keep a strong reference so it doesn't get deallocated.
    private var statusItem: NSStatusItem!

    // Our mouse event interceptor — created once accessibility is confirmed.
    private var mouseInterceptor: MouseInterceptor?

    // Track whether interception is currently enabled.
    private var isEnabled = true

    // The menu item for the toggle, so we can update its title.
    private var toggleMenuItem: NSMenuItem!

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        checkAccessibilityAndStart()
    }

    // MARK: - Status Bar Setup

    /// Creates the menu bar icon and its dropdown menu.
    ///
    /// We use SF Symbols ("computermouse") for the icon — these are built into
    /// macOS and scale properly on all displays (including Retina).
    private func setupStatusBar() {
        // Request a variable-width status item in the system menu bar.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Set the icon. SF Symbols are available on macOS 11+.
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "computermouse", accessibilityDescription: "Mouse Helper")
        }

        // Build the dropdown menu.
        let menu = NSMenu()

        // "Enabled" toggle — lets the user turn interception on/off without quitting.
        toggleMenuItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        toggleMenuItem.target = self
        toggleMenuItem.state = .on  // Start enabled
        menu.addItem(toggleMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Status info line (disabled, just for display)
        let statusLine = NSMenuItem(title: "Middle-click gestures active", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        menu.addItem(NSMenuItem.separator())

        // Quit button
        let quitItem = NSMenuItem(title: "Quit Mouse Helper", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Accessibility Check

    /// Checks if we have Accessibility permission. If not, prompts the user.
    ///
    /// CGEventTap requires Accessibility access to intercept system-wide events.
    /// This is a security feature — the user must explicitly trust our app in
    /// System Settings > Privacy & Security > Accessibility.
    private func checkAccessibilityAndStart() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)

        if trusted {
            startInterceptor()
        } else {
            // The system dialog is now showing. We'll poll briefly to detect
            // when the user grants access, then start automatically.
            print("⚠️  Accessibility access required. Please grant access in System Settings.")
            pollForAccessibility()
        }
    }

    /// Polls every 2 seconds to check if accessibility was granted.
    /// This is a common pattern — there's no callback API for permission changes.
    private func pollForAccessibility() {
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            if AXIsProcessTrusted() {
                timer.invalidate()
                print("✅ Accessibility access granted!")
                self?.startInterceptor()
            }
        }
    }

    // MARK: - Interceptor Management

    private func startInterceptor() {
        guard mouseInterceptor == nil else { return }
        mouseInterceptor = MouseInterceptor()
        mouseInterceptor?.start()
        print("🖱️  Mouse Helper is running. Middle-button gestures are active.")
    }

    // MARK: - Menu Actions

    @objc private func toggleEnabled() {
        isEnabled.toggle()
        toggleMenuItem.state = isEnabled ? .on : .off

        if isEnabled {
            mouseInterceptor?.start()
        } else {
            mouseInterceptor?.stop()
        }
    }

    @objc private func quitApp() {
        mouseInterceptor?.stop()
        NSApp.terminate(nil)
    }
}
