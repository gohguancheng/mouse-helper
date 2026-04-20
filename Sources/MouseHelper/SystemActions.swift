import Cocoa
import CoreGraphics

/// System-level actions triggered by mouse gestures.
///
/// These are kept in a separate file for clean separation of concerns:
/// MouseInterceptor detects *what* gesture happened, SystemActions
/// performs *what should happen*.
enum SystemActions {

    // MARK: - Mission Control

    /// Opens Mission Control by launching its app bundle.
    static func openMissionControl() {
        let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error = error {
                print("❌ Failed to open Mission Control: \(error.localizedDescription)")
            }
        }
    }

    /// Dismisses Mission Control by simulating Escape (keycode 53).
    static func dismissMissionControl() {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false) else { return }
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    // MARK: - Mission Control Detection

    /// Returns true if Mission Control is currently visible (Dock is frontmost).
    static var isMissionControlActive: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.dock"
    }

    // MARK: - Desktop Switching

    /// Direction for desktop switching.
    enum SwipeDirection {
        case left   // Move to the desktop on the left (Control + Left Arrow)
        case right  // Move to the desktop on the right (Control + Right Arrow)
    }

    /// Switches to the adjacent desktop by simulating Control+Arrow via
    /// macOS SymbolicHotKeys. Posts at session tap with numericPad + fn flags
    /// so the SHK system recognizes arrow keys.
    static func switchDesktop(direction: SwipeDirection) {
        DispatchQueue.global(qos: .userInteractive).async {
            let keyCode: CGKeyCode = (direction == .left) ? 123 : 124

            guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
                return
            }

            let originalFlags = keyUp.flags
            keyDown.flags = [.maskControl, .maskNumericPad, .maskSecondaryFn]
            keyUp.flags = originalFlags

            keyDown.post(tap: .cgSessionEventTap)
            keyUp.post(tap: .cgSessionEventTap)
        }
    }
}
