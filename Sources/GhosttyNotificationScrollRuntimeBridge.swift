import Foundation
import CmuxTerminal
import CmuxTerminalCore

extension TerminalPanel {
    func performInternalBindingAction(_ action: String) -> Bool {
        guard !isAgentHibernated else { return false }
        return surface.performInternalBindingAction(action)
    }
}

extension GhosttyApp {
    func handleCurrentDirectoryAction(
        _ directory: String,
        authoritativeGeometry: NotificationScrollRestoreGeometry?,
        surfaceView: GhosttyNSView
    ) {
        let terminalSurface = surfaceView.terminalSurface
        // A bounded per-surface AsyncStream drives one MainActor consumer.
        // Ordinary PWD actions coalesce; registered replay markers
        // remain ordered and cannot be displaced by terminal output floods.
        surfaceView.currentDirectoryActionDispatcher.enqueue(
            directory: directory,
            authoritativeGeometry: authoritativeGeometry,
            surfaceView: surfaceView,
            terminalSurface: terminalSurface
        )
    }
}

extension GhosttyNSView {
    func registerNotificationScrollReplayBoundaries(
        startBoundary: String,
        endBoundary: String
    ) {
        currentDirectoryActionDispatcher = GhosttyCurrentDirectoryActionDispatcher(
            startBoundary: startBoundary,
            endBoundary: endBoundary
        )
    }

    static func retainRenderedFrameNotifications() -> () -> Void {
        // See GhosttyApp.retainTickNotifications() on the idempotent release.
        let retention = GhosttyApp.renderedFrameNotificationDemand.retain()
        return { retention.release() }
    }

    // The two Ghostty scrollbar entry points that used to live here are
    // declared in the `GhosttyNSView` class body instead — see
    // "Scrollbar runtime seam" in GhosttyTerminalView.swift. They must be
    // overridable by the scroll-restore tests' stub subclass, and an extension
    // method is only overridable through `@objc dynamic`, which these
    // signatures can no longer take: `ghostty_surface_scrollbar_s` now arrives
    // through the CmuxTerminalCore Swift module rather than the Objective-C
    // bridging header, so it is not representable in Objective-C.
}
