import Cocoa

// --- App Entry Point ---
// NSApplication.shared is the singleton that represents our running app.
// We assign a delegate to handle lifecycle events, then start the run loop.

let app = NSApplication.shared

// This makes our app a "background" app — no dock icon, no main menu bar.
// Perfect for a utility that lives only in the status bar (menu bar icons).
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate

// This starts the main event loop. The app will keep running until terminated.
// All mouse events, UI updates, and timers are processed through this loop.
app.run()
