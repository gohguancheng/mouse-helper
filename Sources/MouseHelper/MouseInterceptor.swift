import Cocoa
import CoreGraphics

/// Intercepts middle mouse button events and detects gestures.
///
/// Gestures detected:
/// - Long press (hold ~300ms without moving) → Mission Control
/// - Hold + horizontal swipe → Switch desktops
class MouseInterceptor {

    // MARK: - Configuration

    /// How long the user must hold the middle button to trigger a long press (seconds).
    private let longPressDelay: TimeInterval = 0.3

    /// Maximum mouse movement (pixels) during a long press before it's
    /// considered a swipe instead. Mice jitter a few pixels even when
    /// "stationary", so we need some tolerance.
    private let moveThreshold: CGFloat = 10.0

    /// Minimum horizontal movement (pixels) to trigger a desktop switch.
    private let swipeThreshold: CGFloat = 20.0

    // MARK: - State

    /// The possible states of our gesture recognizer.
    private enum GestureState {
        case idle                  // No middle button held
        case pressed               // Middle button down, waiting to classify
        case longPressTriggered    // Long press detected, Mission Control fired
        case swiping               // Horizontal swipe in progress
    }

    private var state: GestureState = .idle

    /// Whether we're currently tracking a middle-button gesture.
    private var isTrackingGesture: Bool {
        state == .pressed || state == .swiping || state == .longPressTriggered
    }

    /// Where the middle button was first pressed (screen coordinates).
    private var pressOrigin: CGPoint = .zero

    /// Timer that fires after `longPressDelay` to detect a long press.
    private var longPressTimer: Timer?

    /// Accumulated horizontal distance during a swipe gesture.
    private var accumulatedDeltaX: CGFloat = 0.0

    /// Track if we already switched desktop in the current swipe to avoid rapid-fire.
    private var hasSwitchedInCurrentSwipe = false

    /// Tracks whether WE opened Mission Control via long press in this gesture.
    /// This is more reliable than querying NSWorkspace for the frontmost app,
    /// because macOS doesn't consistently report the Dock as frontmost when
    /// Mission Control is showing.
    private var missionControlTriggered = false

    /// Re-entrancy guard: when we synthesize a middle click (via synthesizeMiddleClick),
    /// the posted events will flow back through our own event tap. Without this flag,
    /// we'd intercept our own synthetic click and create an infinite loop.
    private var isSynthesizing = false

    // MARK: - Event Tap

    /// The Core Graphics event tap reference. Must be retained while active.
    /// `fileprivate` because the C callback function (declared at file scope
    /// below) needs to access this to re-enable the tap on timeout.
    fileprivate var eventTap: CFMachPort?

    /// The run loop source for the event tap.
    private var runLoopSource: CFRunLoopSource?

    /// Starts intercepting mouse events.
    ///
    /// This creates a CGEventTap — a low-level hook into the macOS input system.
    /// We listen for:
    /// - `.otherMouseDown` / `.otherMouseUp` — middle button press/release
    /// - `.otherMouseDragged` — movement while middle button is held
    /// - `.mouseMoved` — movement (we need this too, as some mice send
    ///   mouseMoved instead of otherMouseDragged)
    func start() {
        // Don't create duplicate taps
        guard eventTap == nil else { return }

        // Define which events we want to intercept.
        // CGEventMask is a bitmask — we OR together the event types we care about.
        let eventMask: CGEventMask = (
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)
        )

        // Create the event tap.
        // Parameters explained:
        // - tap: .cghidEventTap — intercept at the HID (hardware) level
        // - place: .headInsertEventTap — our callback runs before other taps
        // - options: .defaultTap — we can modify/suppress events (not just observe)
        // - eventsOfInterest: our bitmask
        // - callback: C function pointer (see below)
        // - userInfo: pointer to `self` so the C callback can access our Swift object
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: selfPtr
        ) else {
            print("❌ Failed to create event tap. Is Accessibility access granted?")
            return
        }

        eventTap = tap

        // Add the event tap to the current run loop so events actually get delivered.
        // A run loop is macOS's event processing mechanism — think of it as the
        // engine that drives our app's responsiveness.
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)

        // Enable the tap (it starts disabled by default).
        CGEvent.tapEnable(tap: tap, enable: true)

        print("✅ Event tap started")
    }

    /// Stops intercepting mouse events and cleans up.
    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        longPressTimer?.invalidate()
        longPressTimer = nil
        eventTap = nil
        runLoopSource = nil
        state = .idle
        missionControlTriggered = false
        print("🛑 Event tap stopped")
    }

    // MARK: - Event Handling

    /// Processes a mouse event and returns the event to pass through,
    /// or nil to suppress it.
    ///
    /// This is called from the C callback below. We route to specific
    /// handlers based on event type.
    fileprivate func handleEvent(type: CGEventType, event: CGEvent) -> CGEvent? {
        // Re-entrancy guard: if we're currently synthesizing a middle click,
        // let it pass through without interception. Otherwise we'd catch our
        // own synthetic events and loop forever.
        if isSynthesizing {
            return event
        }

        // We only care about the middle button (button number 2).
        // Button 0 = left, button 1 = right, button 2 = middle.
        let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)

        switch type {
        case .otherMouseDown where buttonNumber == 2:
            return handleMiddleMouseDown(event: event)

        case .otherMouseUp where buttonNumber == 2:
            return handleMiddleMouseUp(event: event)

        case .otherMouseDragged where buttonNumber == 2:
            return handleMiddleMouseDragged(event: event)

        case .mouseMoved:
            // Some mice send mouseMoved instead of otherMouseDragged.
            if isTrackingGesture {
                return handleMiddleMouseDragged(event: event)
            }
            return event

        case .scrollWheel:
            return handleScrollWheel(event: event)

        default:
            // Pass through all other events untouched
            return event
        }
    }

    // MARK: - Middle Button Handlers

    /// Middle button pressed down — start tracking the gesture.
    ///
    /// Always starts in .pressed with a long-press timer, regardless of
    /// whether Mission Control is active. This way:
    /// - Long press always toggles MC (open if closed, close if open)
    /// - Short press + drag enters swiping (only switches desktops if MC is active)
    private func handleMiddleMouseDown(event: CGEvent) -> CGEvent? {
        state = .pressed
        pressOrigin = event.location
        accumulatedDeltaX = 0.0
        hasSwitchedInCurrentSwipe = false

        // Start a timer. If it fires without significant movement,
        // we consider it a long press (which will toggle Mission Control).
        longPressTimer?.invalidate()
        longPressTimer = Timer.scheduledTimer(withTimeInterval: longPressDelay, repeats: false) { [weak self] _ in
            self?.handleLongPressTimerFired()
        }

        // Suppress the middle-click so apps don't also receive it
        // (e.g., browsers would open links in new tabs)
        return nil
    }

    /// Middle button released — finalize the gesture.
    private func handleMiddleMouseUp(event: CGEvent) -> CGEvent? {
        longPressTimer?.invalidate()
        longPressTimer = nil

        let previousState = state
        state = .idle

        switch previousState {
        case .pressed:
            // Quick click — not a gesture. Synthesize normal middle click
            // and reset MC flag since user is clearly not in MC workflow.
            missionControlTriggered = false
            synthesizeMiddleClick(at: event.location)
            return nil

        case .longPressTriggered, .swiping:
            // Gesture was handled, just suppress the up event.
            return nil

        default:
            return event
        }
    }

    /// Mouse moved while middle button is held — check for swipe.
    private func handleMiddleMouseDragged(event: CGEvent) -> CGEvent? {
        guard isTrackingGesture else { return event }

        let currentPos = event.location
        let deltaX = currentPos.x - pressOrigin.x
        // Use horizontal distance only so vertical mouse drift doesn't
        // cancel a long press intended as a stationary hold.
        let horizontalMovement = abs(deltaX)

        if state == .pressed {
            if horizontalMovement > moveThreshold {
                longPressTimer?.invalidate()
                longPressTimer = nil
                state = .swiping
                accumulatedDeltaX = deltaX
            }
        } else if state == .longPressTriggered {
            // User keeps holding after MC opened — transition to swiping.
            if horizontalMovement > moveThreshold {
                state = .swiping
                // Reset the origin to the current position so deltaX is measured
                // from where the swipe actually starts, not the original press.
                pressOrigin = currentPos
                accumulatedDeltaX = 0
                // Return early so the `if state == .swiping` block below doesn't
                // overwrite accumulatedDeltaX with a stale deltaX value.
                return nil
            }
        }

        if state == .swiping {
            // Recalculate deltaX from the (possibly updated) pressOrigin.
            let swipeDeltaX = currentPos.x - pressOrigin.x
            accumulatedDeltaX = swipeDeltaX

            if abs(accumulatedDeltaX) > swipeThreshold && !hasSwitchedInCurrentSwipe {
                // Natural direction: drag right → move left
                let direction: SystemActions.SwipeDirection = accumulatedDeltaX > 0 ? .left : .right
                SystemActions.switchDesktop(direction: direction)
                hasSwitchedInCurrentSwipe = true
            }

            // Suppress the drag event so it doesn't affect other apps
            return nil
        }

        return event
    }

    // MARK: - Scroll Wheel (reverse for mouse, keep natural for trackpad)

    /// Inverts scroll direction for mouse scroll events.
    ///
    /// Detection: Trackpad/Magic Mouse events are identified by having
    /// `isContinuous` set, or non-zero scroll/momentum phases. Mouse wheel
    /// events — even high-resolution smooth-scroll wheels — have none of these.
    ///
    /// Approach: Instead of modifying the original event in-place (which
    /// doesn't reliably propagate for scroll events on all macOS versions),
    /// we suppress the original and post a modified copy at the session
    /// event tap level. The session-level post bypasses our HID-level tap,
    /// avoiding re-entrancy issues.
    private func handleScrollWheel(event: CGEvent) -> CGEvent? {
        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let scrollPhase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)

        if isContinuous || scrollPhase != 0 || momentumPhase != 0 {
            return event  // Trackpad/Magic Mouse — leave unchanged
        }

        // Mouse wheel event — suppress original and post inverted copy
        guard let copy = event.copy() else { return event }

        // Invert line deltas (primary scroll unit)
        let deltaY = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let deltaX = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        copy.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -deltaY)
        copy.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -deltaX)

        // Invert point deltas (used by some apps for smooth/pixel scrolling)
        let pointDeltaY = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let pointDeltaX = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        copy.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: -pointDeltaY)
        copy.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: -pointDeltaX)

        // Invert fixed-point deltas
        let fixedDeltaY = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let fixedDeltaX = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        copy.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fixedDeltaY)
        copy.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -fixedDeltaX)

        // Post at session level — bypasses our HID-level tap so no infinite loop
        copy.post(tap: .cgSessionEventTap)
        return nil  // Suppress the original event
    }

    // MARK: - Long Press

    /// Called when the long-press timer fires (user held middle button
    /// for `longPressDelay` seconds without significant movement).
    ///
    /// This TOGGLES Mission Control:
    /// - If MC is not showing → open it
    /// - If MC is showing → dismiss it
    private func handleLongPressTimerFired() {
        guard state == .pressed else { return }

        state = .longPressTriggered

        if missionControlTriggered {
            missionControlTriggered = false
            SystemActions.dismissMissionControl()
        } else {
            missionControlTriggered = true
            SystemActions.openMissionControl()
        }
    }

    // MARK: - Click Synthesis

    /// Re-creates a middle click by posting down + up events.
    /// Used when the user does a quick middle click (not a gesture)
    /// so the click still works normally.
    private func synthesizeMiddleClick(at point: CGPoint) {
        let mouseDown = CGEvent(
            mouseEventSource: nil,
            mouseType: .otherMouseDown,
            mouseCursorPosition: point,
            mouseButton: .center
        )
        let mouseUp = CGEvent(
            mouseEventSource: nil,
            mouseType: .otherMouseUp,
            mouseCursorPosition: point,
            mouseButton: .center
        )

        // Set the re-entrancy guard so our event tap passes these through
        // without trying to intercept them again. Reset on the next run loop
        // iteration because CGEvent.post() is asynchronous — the events may
        // arrive at our tap after this function returns.
        isSynthesizing = true
        mouseDown?.post(tap: .cghidEventTap)
        mouseUp?.post(tap: .cghidEventTap)
        DispatchQueue.main.async { [weak self] in self?.isSynthesizing = false }
    }
}

// MARK: - C Callback

/// CGEventTap requires a C function pointer as a callback. Swift closures
/// can't be used directly because they capture context (a C function pointer
/// must be a pure function).
///
/// We work around this by passing `self` as `userInfo` (an opaque pointer),
/// then recovering it inside the callback.
///
/// IMPORTANT: This function must be declared at module scope (not inside a class)
/// because Swift needs it to have a stable function pointer.
private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    // If the tap gets disabled by the system (e.g., due to timeout),
    // re-enable it. This can happen if our callback takes too long.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo = userInfo {
            let interceptor = Unmanaged<MouseInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
            if let tap = interceptor.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    guard let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let interceptor = Unmanaged<MouseInterceptor>.fromOpaque(userInfo).takeUnretainedValue()

    if let resultEvent = interceptor.handleEvent(type: type, event: event) {
        return Unmanaged.passUnretained(resultEvent)
    } else {
        return nil
    }
}
