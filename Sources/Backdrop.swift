// A wash over everything else while the palette is up.
//
// The palette floats over whatever the user was doing, and over a busy screen
// it competes with it: a page of text behind a page of text. Dimming the rest
// is the oldest trick there is for saying which one is being talked to.
//
// It never takes a click. `ignoresMouseEvents` is the whole safety argument:
// this is a window covering every screen the user owns, and if it ever failed
// to go away, a wash that swallowed clicks would be a locked machine. One that
// does not is a tint, and everything under it is still reachable.
import AppKit

/// Paints the wash itself, in `draw`. Two tidier-looking ways of tinting a
/// window turned out to fail in silence, and both failed identically: the
/// window came up on screen, full size, at alpha 1, and perfectly transparent.
///
/// - `view.wantsLayer = true` followed by `view.layer?.backgroundColor = …`
///   does nothing at all when the layer is not ready on the very next line,
///   and optional chaining swallows it.
/// - `window.backgroundColor` with an alpha needs a display pass that
///   `setFrame(_:display: false)` never asks for.
///
/// A `draw` that fills its rect cannot be skipped and cannot be a no-op.
private final class Wash: NSView {
    var colour: NSColor = .black
    override func draw(_ dirtyRect: NSRect) {
        colour.setFill()
        dirtyRect.fill()
    }
    override var isOpaque: Bool { false }
}

final class Backdrop {
    private let window: NSPanel
    private let wash = Wash()
    private static let opacity: CGFloat = 0.28
    private static let fade: TimeInterval = 0.12

    init() {
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        // Just under the palette, above everything the user was looking at.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        // Follows the user across spaces, and sits beside a full-screen app
        // rather than yanking them out of it.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        wash.colour = NSColor.black.withAlphaComponent(Backdrop.opacity)
        window.contentView = wash
        window.alphaValue = 0
    }

    /// Every screen, not just the one the palette is on: a second display left
    /// bright beside a dimmed one reads as a glitch rather than as focus.
    /// Recomputed at each show, because displays get plugged in.
    func show() {
        let frame = NSScreen.screens.reduce(NSRect.zero) { $0.isEmpty ? $1.frame : $0.union($1.frame) }
        guard !frame.isEmpty else { return }
        window.setFrame(frame, display: true)
        if !window.isVisible {
            window.alphaValue = 0
            window.orderFront(nil)
        }
        wash.needsDisplay = true
        fade(to: 1)
    }

    func hide() {
        guard window.isVisible else { return }
        fade(to: 0) { [window] in window.orderOut(nil) }
    }

    private func fade(to alpha: CGFloat, then done: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Backdrop.fade
            window.animator().alphaValue = alpha
        }, completionHandler: done)
    }
}
