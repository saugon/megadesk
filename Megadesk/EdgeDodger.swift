import AppKit

/// Makes a floating panel "dodge" the mouse: when the cursor approaches, the
/// panel slides toward the nearest side edge (left or right, never top/bottom)
/// and tucks away leaving a thin sliver visible, then slides back once the
/// cursor leaves the area it occupied. Holding a configurable modifier (default
/// Command) suspends the behavior so the panel can be reached and interacted with.
///
/// Detection uses global + local mouse-moved monitors (there is no other way to
/// know the cursor is *near* a window rather than over it). Movement is animated
/// and, while the dodger repositions the panel, it asks the owner to suppress
/// its position persistence so the tucked-away spot is never saved as the
/// resting position.
final class EdgeDodger {

    /// Proximity margin (pt) around the panel that triggers the dodge, and the
    /// area the cursor must leave before the panel returns.
    private let margin: CGFloat = 36
    private let animationDuration: TimeInterval = 0.22

    private weak var window: NSWindow?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// The panel's resting frame while shown; refreshed as the user moves it.
    private var homeFrame: NSRect = .zero
    private var isTucked = false
    private var isAnimating = false
    /// Which side the panel tucked to, and how much sliver is currently shown
    /// (grows while the cursor hovers the sliver, if hover-peek is enabled).
    private var tuckedToRight = true
    private var currentReveal: CGFloat = 0
    /// True once the user engages the panel (holds the bypass key with the
    /// cursor over it). While engaged the panel stays pinned in place until the
    /// cursor leaves it, even after the key is released.
    private var isEngaged = false
    /// Pending release of the engaged state after the cursor leaves the panel.
    private var disengageWorkItem: DispatchWorkItem?
    /// Grace period before an engaged panel is allowed to hide once the cursor
    /// leaves it, so a quick out-and-back doesn't flicker hide/show.
    private let disengageDelay: TimeInterval = 0.25
    /// Pending revert of a hover-grown sliver after the cursor leaves it.
    private var peekGraceWorkItem: DispatchWorkItem?
    /// Grace period before a hover-grown sliver shrinks back once the cursor
    /// leaves it, so a quick move away (even across the screen) doesn't snap it
    /// back if the cursor returns.
    private let peekGraceDelay: TimeInterval = 0.25

    /// Whether dodging may run right now (feature on + panel applicable & visible).
    var shouldApply: () -> Bool = { false }
    /// Modifier flags that, while held, suspend dodging.
    var bypassFlags: () -> NSEvent.ModifierFlags = { .command }
    /// Lets the owner suppress its position persistence while the dodger moves.
    var setSuppressSave: (Bool) -> Void = { _ in }

    init(window: NSWindow?) {
        self.window = window
    }

    var isRunning: Bool { globalMonitor != nil }

    func start() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .flagsChanged]
        ) { [weak self] _ in
            self?.evaluate()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .flagsChanged]
        ) { [weak self] event in
            self?.evaluate()
            return event
        }
    }

    func stop() {
        if let g = globalMonitor { NSEvent.removeMonitor(g); globalMonitor = nil }
        if let l = localMonitor { NSEvent.removeMonitor(l); localMonitor = nil }
        cancelDisengage()
        cancelPeekGrace()
        isEngaged = false
        if isTucked { untuck() }
    }

    private func evaluate() {
        guard window != nil else { return }
        guard shouldApply() else {
            // Feature turned off or panel no longer applicable (e.g. collapsed to
            // the peek tab): don't leave it stranded off-screen.
            if isTucked, !isAnimating { untuck() }
            isEngaged = false
            cancelDisengage()
            cancelPeekGrace()
            return
        }
        guard !isAnimating, let window else { return }

        let mouse = NSEvent.mouseLocation
        let holding = NSEvent.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(bypassFlags())
        // The modifier's role is configurable: it can either suspend dodging
        // while held (default) or be what enables dodging in the first place.
        let mode = AppSettings.shared.edgeDodgeTriggerMode
        let dodgingSuspended = (mode == .dodgeUnlessHeld) ? holding : !holding

        // Once engaged, stay pinned in place even after the modifier is
        // released, so it can't slide away while the user is interacting with
        // it. When the cursor leaves, wait a short grace period before letting
        // it hide, so a quick out-and-back doesn't flicker hide/show.
        if isEngaged {
            if window.frame.contains(mouse) {
                cancelDisengage()  // back over the panel; stay engaged
                homeFrame = window.frame
            } else {
                scheduleDisengage()
            }
            return
        }

        if dodgingSuspended {
            if isTucked {
                untuck()
            } else if mode == .dodgeUnlessHeld, window.frame.contains(mouse) {
                // In the default mode, holding the key with the cursor over the
                // panel means the user is interacting: pin it (engage) so it
                // won't hide when the key is released. In the inverted mode the
                // panel is at rest anyway, so there's nothing to pin.
                isEngaged = true
                cancelDisengage()
                homeFrame = window.frame
            }
            return
        }

        if isTucked {
            let base = baseReveal
            let peeked = hoverReveal
            // Uses the *current* sliver size for hysteresis so the grow/shrink
            // edge doesn't flicker.
            let overSliver = visibleSliverRect(reveal: currentReveal).contains(mouse)

            if overSliver {
                // Cursor over the sliver: cancel any pending revert and grow it.
                cancelPeekGrace()
                if abs(peeked - currentReveal) > 0.5, let target = sideTuckedFrame(reveal: peeked) {
                    currentReveal = peeked
                    animate(to: target)
                }
                return
            }

            if currentReveal > base + 0.5 {
                // The sliver was grown on hover and the cursor just left it: wait
                // a grace period before reverting, so moving away briefly (or
                // darting across the screen and back) doesn't snap it shut.
                schedulePeekGrace()
                return
            }

            // Base sliver: stay tucked while the cursor is anywhere over the
            // panel's path (its resting spot, the sliver, or the space between).
            // Return the widget only once it leaves that whole area.
            let occupied = homeFrame.union(window.frame).insetBy(dx: -margin, dy: -margin)
            if !occupied.contains(mouse) {
                untuck()
            }
        } else {
            homeFrame = window.frame  // keep the resting position current
            if window.frame.insetBy(dx: -margin, dy: -margin).contains(mouse) {
                tuckToNearestEdge()
            }
        }
    }

    /// The panel's own width. The tucked frame keeps the resting size, so this
    /// is both what a percentage reveal is measured against and the point past
    /// which revealing more would push the panel inward instead of showing more
    /// of it.
    private var panelWidth: CGFloat {
        homeFrame.width > 0 ? homeFrame.width : (window?.frame.width ?? 0)
    }

    /// Caps a reveal at the panel's width (no-op if the width isn't known yet).
    private func clampToPanel(_ reveal: CGFloat) -> CGFloat {
        panelWidth > 0 ? min(reveal, panelWidth) : reveal
    }

    /// Sliver left visible while tucked and unhovered.
    private var baseReveal: CGFloat {
        clampToPanel(CGFloat(AppSettings.shared.edgeDodgeReveal))
    }

    /// Sliver while the cursor hovers it: a share of the panel's own width, so
    /// the setting means the same thing whatever the panel currently measures
    /// and 100% brings it fully into view.
    private var hoverReveal: CGFloat {
        let base = baseReveal
        guard AppSettings.shared.edgeDodgeHoverPeekEnabled else { return base }
        let share = panelWidth * CGFloat(AppSettings.shared.edgeDodgeHoverRevealPercent) / 100
        return clampToPanel(max(base, share))
    }

    private func tuckToNearestEdge() {
        guard let screen = window?.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        let f = homeFrame
        // Always tuck to a side edge (left or right), never top or bottom.
        tuckedToRight = (vf.maxX - f.maxX) <= (f.minX - vf.minX)
        currentReveal = baseReveal
        guard let target = sideTuckedFrame(reveal: currentReveal) else { return }
        isTucked = true
        setSuppressSave(true)
        animate(to: target)
    }

    /// The panel's frame tucked to the current side, showing `reveal` pt.
    private func sideTuckedFrame(reveal: CGFloat) -> NSRect? {
        guard let screen = window?.screen ?? NSScreen.main else { return nil }
        let vf = screen.visibleFrame
        var f = homeFrame
        f.origin.x = tuckedToRight ? vf.maxX - reveal : vf.minX + reveal - f.width
        return f
    }

    /// The on-screen sliver rectangle for a given reveal, used to detect hover.
    private func visibleSliverRect(reveal: CGFloat) -> NSRect {
        guard let screen = window?.screen ?? NSScreen.main else { return .zero }
        let vf = screen.visibleFrame
        let x = tuckedToRight ? vf.maxX - reveal : vf.minX
        return NSRect(x: x, y: homeFrame.minY, width: reveal, height: homeFrame.height)
    }

    private func untuck() {
        isTucked = false
        cancelPeekGrace()
        animate(to: homeFrame) { [weak self] in
            self?.setSuppressSave(false)
        }
    }

    /// Schedules release of the engaged state after `disengageDelay`, unless the
    /// cursor returns to the panel first (which cancels it). Only releases if the
    /// cursor is still outside when it fires, then re-evaluates so it can hide.
    private func scheduleDisengage() {
        guard disengageWorkItem == nil else { return }  // already pending
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.disengageWorkItem = nil
            guard let window = self.window else { return }
            if window.frame.contains(NSEvent.mouseLocation) { return }  // came back
            self.isEngaged = false
            self.evaluate()
        }
        disengageWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + disengageDelay, execute: work)
    }

    private func cancelDisengage() {
        disengageWorkItem?.cancel()
        disengageWorkItem = nil
    }

    /// After the sliver grew on hover, wait before shrinking it back so a brief
    /// move away (or a dart across the screen) doesn't revert it. Only reverts if
    /// the cursor is still off the sliver when it fires, then re-evaluates.
    private func schedulePeekGrace() {
        guard peekGraceWorkItem == nil else { return }  // already pending
        let work = DispatchWorkItem { [weak self] in
            guard let self, let window = self.window else { return }
            self.peekGraceWorkItem = nil
            guard self.isTucked else { return }
            let mouse = NSEvent.mouseLocation
            // Cursor came back over the sliver: keep it grown.
            if self.visibleSliverRect(reveal: self.currentReveal).contains(mouse) { return }
            let occupied = self.homeFrame.union(window.frame).insetBy(dx: -self.margin, dy: -self.margin)
            if !occupied.contains(mouse) {
                // Cursor moved well clear of the panel: there's nothing to dodge,
                // so bring the widget back instead of hiding it to the sliver.
                self.untuck()
            } else {
                // Still lingering near the panel: shrink back to the base sliver.
                let base = self.baseReveal
                if abs(base - self.currentReveal) > 0.5, let target = self.sideTuckedFrame(reveal: base) {
                    self.currentReveal = base
                    self.animate(to: target)
                }
            }
        }
        peekGraceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + peekGraceDelay, execute: work)
    }

    private func cancelPeekGrace() {
        peekGraceWorkItem?.cancel()
        peekGraceWorkItem = nil
    }

    private func animate(to frame: NSRect, completion: (() -> Void)? = nil) {
        guard let window else { completion?(); return }
        isAnimating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = animationDuration
            ctx.allowsImplicitAnimation = true
            window.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in
            self?.isAnimating = false
            completion?()
            // Re-evaluate against the cursor's current position. A fast move to
            // the edge can finish while we're mid-animation, with no further
            // mouse event to drive the follow-up (e.g. the hover grow). Reading
            // the live location avoids waiting for the next movement.
            self?.evaluate()
        })
    }
}
